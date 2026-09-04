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

@Observable
final class CommentOutbox {
    private struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        var operations: [PendingCommentOperation]
    }

    private static let keyPrefix = "vikunja.commentOutbox.v1"
    private let key: String
    private let defaults: UserDefaults
    private(set) var operations: [PendingCommentOperation] = []

    init(defaults: UserDefaults = .standard, accountId: UUID? = nil) {
        self.defaults = defaults
        self.key = accountId.map { "\(Self.keyPrefix).\($0.uuidString)" } ?? Self.keyPrefix
        load()
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
            operations[index].state = .pending
            operations[index].errorMessage = nil
        } else if let serverId {
            operations.removeAll {
                if case .update(let queuedId) = $0.kind { return queuedId == serverId }
                return false
            }
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
            operations.removeAll {
                if case .update(let queuedId) = $0.kind { return queuedId == serverId }
                return false
            }
            operations.append(PendingCommentOperation(
                id: UUID(), clientCommentId: clientCommentId, taskRef: taskRef, text: "",
                kind: .delete(serverId: serverId), state: .pending, errorMessage: nil, timestamp: .now
            ))
        }
        persist()
    }

    func remap(taskClientId: UUID, toServerId serverId: Int) {
        for index in operations.indices where operations[index].taskRef == .client(taskClientId) {
            operations[index].taskRef = .server(serverId)
        }
        persist()
    }

    func markRetryableFailure(id: UUID, message: String?) {
        updateState(id: id, state: .retryableFailed, message: message)
    }

    func markPermanentFailure(id: UUID, message: String?) {
        updateState(id: id, state: .permanentlyFailed, message: message)
    }

    func retry(id: UUID) {
        updateState(id: id, state: .pending, message: nil)
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
            case .delete:
                state = .deleting
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

    func blocksRefresh(for taskRef: TaskRef) -> Bool {
        operations.contains { $0.taskRef == taskRef && ($0.state == .pending || $0.state == .retryableFailed) }
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
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Envelope.currentVersion else {
                return
            }
            operations = envelope.operations
        } catch {
        }
    }

    private func persist() {
        do {
            let envelope = Envelope(version: Envelope.currentVersion, operations: operations)
            defaults.set(try JSONEncoder().encode(envelope), forKey: key)
        } catch {
        }
    }
}
