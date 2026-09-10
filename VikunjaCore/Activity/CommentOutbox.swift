import Foundation
import Observation

/// A versioned comment queue deliberately separate from `PendingOp`: a malformed
/// comment record must never make the existing task-operation queue undecodable.
enum CommentOperationState: String, Codable, Equatable {
    case pending
    case retryableFailed
    case permanentlyFailed
}

enum CommentOperationKind: Codable, Equatable {
    case create
    case update(serverId: Int)
    case delete(serverId: Int)
}

struct PendingCommentOperation: Codable, Identifiable, Equatable {
    let id: UUID
    let clientCommentId: UUID
    var taskRef: TaskRef
    var text: String
    var kind: CommentOperationKind
    var state: CommentOperationState
    var errorMessage: String?
    let timestamp: Date

    /// Optional on purpose. Synthesized `Decodable` does not fall back to a
    /// property's default value, so a non-optional field here would make every
    /// record written before this build undecodable — and the per-record
    /// isolation in `load()` would then quietly drop them all.
    var attempts: Int?

    /// Set when a create failed with no answer, so it may or may not have
    /// reached the server. Such an op must never re-enter the drain by itself;
    /// only an explicit, informed Retry may send it a second time.
    ///
    /// Optional for the same reason as `attempts`.
    var mayHavePosted: Bool?

    var attemptCount: Int { attempts ?? 0 }
}

struct LocalCommentOverlay: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case retryableFailed(String?)
        case permanentlyFailed(String?)
        case deleting
    }

    let id: UUID
    let taskRef: TaskRef
    let text: String
    let timestamp: Date
    let serverId: Int?
    let state: State
}

/// What `load()` found wrong, if anything. Surfaced as state rather than logged
/// from here: this type is deliberately Foundation-only so the unit-test bundle
/// can compile it without dragging in `VikunjaConfig` and the Keychain.
enum CommentOutboxLoadIssue: Equatable {
    /// Individual records were malformed and skipped; the rest survived.
    case droppedRecords(Int)
    /// The whole payload was undecodable. It has been copied to a quarantine
    /// key and this queue starts empty.
    case unreadable
    /// Written by a newer build. The queue is empty AND read-only, so we do
    /// not overwrite data this version cannot represent.
    case newerSchema(found: Int)
}

@Observable
final class CommentOutbox {
    private struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        var operations: [PendingCommentOperation]
    }

    /// Decode-side twin of `Envelope`. Each element decodes independently, so a
    /// single malformed record cannot make the whole array undecodable and take
    /// every other queued comment with it.
    private struct LenientEnvelope: Decodable {
        let version: Int
        let operations: [Lenient<PendingCommentOperation>]
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private static let keyPrefix = "vikunja.commentOutbox.v1"
    private let key: String
    private var quarantineKey: String { "\(key).quarantine" }
    private let defaults: UserDefaults
    private(set) var operations: [PendingCommentOperation] = []

    /// Set when the persisted payload was written by a newer schema version.
    /// `persist()` becomes a no-op: an empty v1 envelope written over a v2
    /// payload would destroy a queue this build merely cannot read.
    private(set) var isReadOnly = false
    private(set) var loadIssue: CommentOutboxLoadIssue?

    init(defaults: UserDefaults = .standard, accountId: UUID? = nil) {
        self.defaults = defaults
        self.key = accountId.map { "\(Self.keyPrefix).\($0.uuidString)" } ?? Self.keyPrefix
        load()
    }

    /// Every persisted key this outbox owns, so account deletion can purge them.
    static func persistedKeys(accountId: UUID) -> [String] {
        let base = "\(keyPrefix).\(accountId.uuidString)"
        return [base, "\(base).quarantine"]
    }

    func create(taskRef: TaskRef, text: String) -> PendingCommentOperation {
        let op = PendingCommentOperation(
            id: UUID(), clientCommentId: UUID(), taskRef: taskRef, text: text,
            kind: .create, state: .pending, errorMessage: nil, timestamp: .now
        )
        operations.append(op)
        persist()
        return op
    }

    func update(taskRef: TaskRef, serverId: Int?, clientCommentId: UUID, text: String) {
        if let index = operations.firstIndex(where: { $0.clientCommentId == clientCommentId && $0.kind == .create }) {
            operations[index].text = text
            // An ambiguous create may already be on the server. Editing it
            // records the text the user wants to end up with, but must NOT put
            // it back in the drain: doing so posted a second copy of a comment
            // that had very likely landed, which is exactly what the
            // ambiguous-create rule exists to prevent — and it was reached by
            // an ordinary edit, with the "may already have posted" warning
            // still on screen and no confirmation of any kind.
            guard operations[index].mayHavePosted != true else { persist(); return }
            operations[index].state = .pending
            operations[index].errorMessage = nil
            // Fresh work, like `convertCreateToUpdate` and `retry`. Left alone,
            // an edited create inherited the spent budget and could give up
            // after a single attempt.
            operations[index].attempts = 0
        } else if let serverId, !hasQueuedDelete(forServerId: serverId) {
            // Refuse rather than displace when a delete is already queued:
            // replacing it would resurrect a comment the user deleted.
            removeQueuedOps(forServerId: serverId)
            operations.append(PendingCommentOperation(
                id: UUID(), clientCommentId: clientCommentId, taskRef: taskRef, text: text,
                kind: .update(serverId: serverId), state: .pending, errorMessage: nil, timestamp: .now
            ))
        }
        persist()
    }

    func delete(taskRef: TaskRef, serverId: Int?, clientCommentId: UUID) {
        if let index = operations.firstIndex(where: { $0.clientCommentId == clientCommentId && $0.kind == .create }) {
            operations.remove(at: index)
        } else if let serverId {
            removeQueuedOps(forServerId: serverId)
            operations.append(PendingCommentOperation(
                id: UUID(), clientCommentId: clientCommentId, taskRef: taskRef, text: "",
                kind: .delete(serverId: serverId), state: .pending, errorMessage: nil, timestamp: .now
            ))
        }
        persist()
    }

    /// Displace every queued op targeting this comment, whatever its kind.
    ///
    /// This used to match `.update` only, so a queued `.delete` was never
    /// displaced and a second delete appended a second op for the same
    /// serverId. `TaskActivityProjection` keys overlays by serverId, and that
    /// duplicate pair trapped on `Dictionary(uniqueKeysWithValues:)` — a crash
    /// on every open of the task, persisted, with no in-app way out.
    private func removeQueuedOps(forServerId serverId: Int) {
        operations.removeAll {
            switch $0.kind {
            case .create: return false
            case .update(let id), .delete(let id): return id == serverId
            }
        }
    }

    private func hasQueuedDelete(forServerId serverId: Int) -> Bool {
        operations.contains {
            if case .delete(let id) = $0.kind { return id == serverId }
            return false
        }
    }

    /// The create landed, but the user edited the text while it was in flight.
    /// Turn the queued create into an update against the id the server just
    /// gave us, so the next pass sends the new text rather than posting a
    /// second comment. Resets the retry budget: this is fresh work.
    func convertCreateToUpdate(id: UUID, serverId: Int) {
        guard let index = operations.firstIndex(where: { $0.id == id }),
              case .create = operations[index].kind else { return }
        operations[index].kind = .update(serverId: serverId)
        operations[index].state = .pending
        operations[index].errorMessage = nil
        operations[index].attempts = 0
        persist()
    }

    func remap(taskClientId: UUID, toServerId serverId: Int) {
        for index in operations.indices where operations[index].taskRef == .client(taskClientId) {
            operations[index].taskRef = .server(serverId)
        }
        persist()
    }

    /// Retries are bounded. Without a ceiling a 403 on someone else's comment,
    /// or a token that will never regain write scope, is re-sent on every 60 s
    /// poll forever and the user is never told: `hasFailure` only reports
    /// `permanentlyFailed`, so no banner ever appears.
    static let maxRetryAttempts = 5

    func markRetryableFailure(id: UUID, message: String?) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        let attempts = operations[index].attemptCount + 1
        operations[index].attempts = attempts
        operations[index].state = attempts >= Self.maxRetryAttempts ? .permanentlyFailed : .retryableFailed
        operations[index].errorMessage = message
        persist()
    }

    /// `mayHavePosted` marks the ambiguous case: the request went out and no
    /// answer came back, so the server may hold this comment already.
    func markPermanentFailure(id: UUID, message: String?, mayHavePosted: Bool = false) {
        updateState(id: id, state: .permanentlyFailed, message: message)
        guard mayHavePosted, let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].mayHavePosted = true
        persist()
    }

    /// A deferral, not a failure: the server asked us to slow down, which says
    /// nothing about this operation. Leaves `attempts` untouched, or five
    /// throttles across five polls would permanently fail a perfectly valid
    /// comment and strand the user's text.
    func markDeferred(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].state = .pending
        operations[index].errorMessage = nil
        persist()
    }

    /// Explicit user retry clears the ceiling: they have seen the error and
    /// chosen to try again, which is a different thing from the drain looping.
    func retry(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].attempts = 0
        operations[index].state = .pending
        operations[index].errorMessage = nil
        persist()
    }

    func acknowledge(id: UUID) {
        operations.removeAll { $0.id == id }
        persist()
    }

    func eligibleOperations() -> [PendingCommentOperation] {
        operations.filter {
            guard $0.state == .pending || $0.state == .retryableFailed else { return false }
            if case .server = $0.taskRef { return true }
            return false
        }
    }

    func overlays(for taskRef: TaskRef) -> [LocalCommentOverlay] {
        operations.compactMap { op in
            guard op.taskRef == taskRef else { return nil }
            let state: LocalCommentOverlay.State
            switch op.kind {
            case .delete where op.state != .permanentlyFailed:
                // Still on its way — the comment stays hidden.
                state = .deleting
            case .delete:
                // Gave up. The comment is still live on the server for everyone
                // else, so hiding it tells the user it is gone when it is not,
                // with no way to find out and nothing to act on.
                state = .permanentlyFailed(op.errorMessage)
            default:
                switch op.state {
                case .pending: state = .pending
                case .retryableFailed: state = .retryableFailed(op.errorMessage)
                case .permanentlyFailed: state = .permanentlyFailed(op.errorMessage)
                }
            }
            return LocalCommentOverlay(
                id: op.clientCommentId, taskRef: op.taskRef, text: op.text,
                timestamp: op.timestamp,
                serverId: {
                    switch op.kind {
                    case .create: return nil
                    case .update(let id), .delete(let id): return id
                    }
                }(), state: state
            )
        }
    }

    /// Only `.pending` blocks. A `.retryableFailed` op is not in flight, and its
    /// overlay already shadows the server copy in the projection — so blocking on
    /// it bought nothing and cost everything: the activity list stopped fetching
    /// for that task, permanently and silently, because the failure banner is
    /// driven by `hasFailure` (permanent only) and nothing else said why.
    func blocksRefresh(for taskRef: TaskRef) -> Bool {
        operations.contains { $0.taskRef == taskRef && $0.state == .pending }
    }

    func hasFailure(for taskRef: TaskRef) -> Bool {
        operations.contains { $0.taskRef == taskRef && $0.state == .permanentlyFailed }
    }

    private func updateState(id: UUID, state: CommentOperationState, message: String?) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].state = state
        operations[index].errorMessage = message
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }

        guard let envelope = try? JSONDecoder().decode(LenientEnvelope.self, from: data) else {
            // Nothing readable at all. Keep the bytes under a quarantine key
            // instead of letting the next persist() overwrite them: a decoder
            // bug is recoverable from the original data, not from what we
            // replaced it with.
            defaults.set(data, forKey: quarantineKey)
            loadIssue = .unreadable
            return
        }

        // A newer build wrote this. Start empty and refuse to write, rather
        // than clobbering a queue this version cannot represent.
        guard envelope.version <= Envelope.currentVersion else {
            isReadOnly = true
            loadIssue = .newerSchema(found: envelope.version)
            return
        }

        operations = envelope.operations.compactMap(\.value)
        let dropped = envelope.operations.count - operations.count
        if dropped > 0 {
            // Same reasoning as the unreadable branch, which this originally
            // missed: the first persist() rewrites the key with only the
            // survivors, so the dropped records — and the user's unsent text in
            // them — are gone for good. A decoder bug affecting one field shape
            // lands here, not in the whole-payload branch, so it is if anything
            // the more likely path.
            defaults.set(data, forKey: quarantineKey)
            loadIssue = .droppedRecords(dropped)
        }
    }

    private func persist() {
        guard !isReadOnly else { return }
        do {
            let envelope = Envelope(version: Envelope.currentVersion, operations: operations)
            defaults.set(try JSONEncoder().encode(envelope), forKey: key)
        } catch {
            // Encoding our own Codable types cannot fail in practice, but if it
            // ever does the queue is not durable and that must not be silent.
            loadIssue = .unreadable
        }
    }
}
