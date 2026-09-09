import Foundation
import Observation

// MARK: - Task Activity: the companion (fork addition)

/// The Activity feature's own store, hung off `TaskStore` as a single property.
///
/// A companion object rather than an extension because an extension cannot add
/// stored properties, and a static side-table would not be observed — SwiftUI
/// has to see the comment queue change. So the whole of the feature's mutable
/// state lives here, and `TaskStore` carries exactly three fork lines: the
/// property, `attach(to:)` at the end of `init`, and `reset(accountId:)` at the
/// end of `resetPerAccountState`.
///
/// It couples to upstream by *observing* rather than by being called:
///
/// - the falling edge of `store.isDraining` runs the comment drain, which is
///   strictly better than the three call sites it replaces (reachability, the
///   60 s poll, "Try Again"), because it necessarily runs *after* the task
///   drain, so an offline-created task's comments are already remapped;
/// - the falling edge of `store.isLoading` re-reads the server capabilities and
///   repairs a failed identity fetch;
/// - `Outbox.didRemap` carries the client-id -> server-id remap across.
///
/// `drainOutbox()` raises `isDraining` before it checks whether the queue is
/// empty, so every drain — poll, reachability, scene activation, "Try Again" —
/// produces an observable true->false edge even with no task ops queued. That
/// is what makes observation a complete replacement for the call sites.
@Observable
@MainActor
final class TaskActivityCompanion {

    private(set) var commentOutbox: CommentOutbox

    /// Readable so the sheet can disable its actions while a comment drain is
    /// running; `discardAny`/`discardEverything` refuse in that window.
    private(set) var isDraining = false

    /// Set when a drain is requested while one is already running, so the
    /// request is honored by another pass rather than thrown away.
    private var drainRequestedWhileDraining = false

    /// Observable mirror of `VikunjaAPI.supportsComments`, which is a plain
    /// UserDefaults read written by the once-per-launch `/info` probe. SwiftUI
    /// has no dependency on a defaults key, so a view that read the static
    /// directly kept whatever value it saw on first render — a task editor
    /// opened before the probe landed hid the composer for its whole life on a
    /// perfectly capable server.
    private(set) var supportsComments = VikunjaAPI.supportsComments

    /// The authenticated user's identity, cached for the life of the account.
    ///
    /// Vikunja returns no per-comment permission field, so the client decides
    /// whether a comment is yours by comparing `comment.author.id` against this.
    /// It used to be fetched per view with `try?` and cached nowhere, so one
    /// dropped `GET /user` left it nil, every comment failed the ownership test,
    /// and edit/delete silently disappeared from your own comments until you
    /// closed and reopened the task.
    private(set) var currentUser: VikunjaCurrentUser?

    /// Weak: `TaskStore` owns this object.
    @ObservationIgnored private weak var store: TaskStore?

    init() {
        commentOutbox = CommentOutbox(accountId: VikunjaConfig.activeAccount?.id)
    }

    // MARK: - Lifecycle

    /// Called at the end of `TaskStore.init`.
    ///
    /// The initial drain is not redundant with the observers: comments
    /// persisted across a launch have to go out even if no task op is ever
    /// queued, and nothing else would raise `isDraining`.
    func attach(to store: TaskStore) {
        self.store = store
        hookRemap()
        logLoadIssue()
        purgeOrphanAccountKeys()
        observeTaskDrain()
        observeRefresh()
        Task { await drain() }
    }

    /// Called at the end of `TaskStore.resetPerAccountState`, which has already
    /// replaced `store.outbox` by then — so the remap hook has to be re-armed
    /// onto the new instance.
    func reset(accountId: UUID?) {
        commentOutbox = CommentOutbox(accountId: accountId)
        // Identity is per-account. Leaving the old one cached would let the
        // previous account's id decide which comments look editable.
        currentUser = nil
        hookRemap()
        logLoadIssue()
        purgeOrphanAccountKeys()
    }

    private func hookRemap() {
        store?.outbox.didRemap = { [weak self] clientId, serverId in
            self?.commentOutbox.remap(taskClientId: clientId, toServerId: serverId)
        }
    }

    // MARK: - Observation

    /// Re-arms *before* acting: `withObservationTracking` fires once, so
    /// re-arming after an `await` would drop every edge that landed during the
    /// work. `onChange` runs on `willSet`, which is why the value is read
    /// inside the hop rather than in the closure.
    private func observeTaskDrain() {
        guard let store else { return }
        withObservationTracking {
            _ = store.isDraining
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeTaskDrain()
                guard self.store?.isDraining == false else { return }
                await self.drain()
            }
        }
    }

    private func observeRefresh() {
        guard let store else { return }
        withObservationTracking {
            _ = store.isLoading
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeRefresh()
                guard self.store?.isLoading == false else { return }
                self.refreshServerCapabilities()
                await self.loadCurrentUserIfNeeded()
            }
        }
    }

    // MARK: - Server capabilities and identity

    func refreshServerCapabilities() {
        supportsComments = VikunjaAPI.supportsComments
    }

    /// Best-effort and idempotent. Failing to learn who you are must not stop
    /// the timeline rendering, so the error is swallowed — but it is retried on
    /// the next refresh rather than persisting for the life of a view.
    func loadCurrentUserIfNeeded() async {
        guard currentUser == nil, VikunjaAPI.supportsComments else { return }
        currentUser = try? await VikunjaAPI.fetchCurrentUser()
    }

    // MARK: - Queueing

    func queueComment(task: VikunjaTask, text: String) {
        guard let ref = taskRef(for: task) else { return }
        _ = commentOutbox.create(taskRef: ref, text: text)
        Task { await drain() }
    }

    /// `clientCommentId` must be the real one from the row's overlay, not a
    /// fresh UUID. Passing a fresh one made `CommentOutbox`'s create-coalescing
    /// branch unreachable from the app: editing a comment that had not been
    /// sent yet appended a second operation instead of amending the first, and
    /// the branch was only ever exercised by its own unit test.
    ///
    /// `commentId` is nil while the comment is still queued and has no server
    /// id yet — that is precisely the case coalescing exists for.
    func queueCommentUpdate(task: VikunjaTask, commentId: Int?, clientCommentId: UUID, text: String) {
        guard let ref = taskRef(for: task) else { return }
        commentOutbox.update(taskRef: ref, serverId: commentId, clientCommentId: clientCommentId, text: text)
        Task { await drain() }
    }

    func queueCommentDelete(task: VikunjaTask, commentId: Int?, clientCommentId: UUID) {
        guard let ref = taskRef(for: task) else { return }
        commentOutbox.delete(taskRef: ref, serverId: commentId, clientCommentId: clientCommentId)
        Task { await drain() }
    }

    /// Send a given-up comment operation again, at the user's explicit request.
    ///
    /// Without this, `retry(id:)` had no caller at all: the retry ceiling and
    /// the ambiguous-create rule both push operations to `permanentlyFailed`,
    /// the Activity banner routes the user to the Pending Changes sheet, and
    /// that sheet only offered Discard. The user's authored text could be
    /// thrown away and nothing else.
    func retryComment(opId: UUID) async {
        guard commentOutbox.operations.contains(where: { $0.id == opId }) else { return }
        commentOutbox.retry(id: opId)
        await drain()
    }

    func retryAllFailed() {
        for op in commentOutbox.operations where op.state == .permanentlyFailed {
            commentOutbox.retry(id: op.id)
        }
    }

    func acknowledgeAll() -> Int {
        let queued = commentOutbox.operations
        for op in queued { commentOutbox.acknowledge(id: op.id) }
        return queued.count
    }

    func acknowledgeChildren(ofClientTask uuid: UUID) {
        for op in commentOutbox.operations where op.taskRef == .client(uuid) {
            commentOutbox.acknowledge(id: op.id)
        }
    }

    private func taskRef(for task: VikunjaTask) -> TaskRef? {
        if task.id > 0 { return .server(task.id) }
        return store?.outbox.clientId(forPlaceholder: task.id).map(TaskRef.client)
    }

    // MARK: - Drain

    func drain() async {
        guard !isDraining else {
            drainRequestedWhileDraining = true
            return
        }
        guard let store, store.reachability.isOnline else { return }
        isDraining = true
        defer { isDraining = false }

        sweepOrphans()

        // Address the outbox this drain started with, not whatever
        // `commentOutbox` points at after an await. `reset(accountId:)`
        // replaces the instance on an account switch, so a bare
        // `commentOutbox.acknowledge(...)` after the network call would run
        // against the NEW account's queue, match nothing, and leave the sent op
        // sitting `.pending` under the old account's key — reposting the
        // comment when the user switches back. That is the duplicate-post
        // hazard the ambiguous-create rule exists to prevent, reached through a
        // path with no user review at all.
        let outbox = commentOutbox

        repeat {
            drainRequestedWhileDraining = false
            let snapshot = outbox.eligibleOperations()
            for op in snapshot {
                guard case .server(let taskId) = op.taskRef else { continue }
                do {
                    switch op.kind {
                    case .create:
                        let created = try await VikunjaAPI.createComment(taskId: taskId, comment: op.text)
                        // The op may have changed while the request was in
                        // flight. @MainActor means that can only have happened
                        // during the await, but it does NOT mean this check can
                        // be a mere existence test: `CommentOutbox.update`
                        // coalesces an edit by mutating the text in place and
                        // KEEPING the same id, so `contains(id:)` passes and
                        // acknowledging would throw the user's edit away while
                        // the server keeps the pre-edit body.
                        switch outbox.operations.first(where: { $0.id == op.id }) {
                        case .none:
                            // Cancelled mid-flight. The comment exists on the
                            // server now, so delete it: cancel means cancel.
                            try? await VikunjaAPI.deleteComment(taskId: taskId, commentId: created.id)
                        case .some(let current) where current.text != op.text:
                            // Edited mid-flight. The create landed with the old
                            // text; convert the queued op into an update against
                            // the id we just learned, so the next pass sends the
                            // new text instead of posting a second comment.
                            outbox.convertCreateToUpdate(id: op.id, serverId: created.id)
                        default:
                            outbox.acknowledge(id: op.id)
                        }
                        continue
                    case .update(let commentId):
                        try await VikunjaAPI.updateComment(taskId: taskId, commentId: commentId, comment: op.text)
                    case .delete(let commentId):
                        try await VikunjaAPI.deleteComment(taskId: taskId, commentId: commentId)
                    }
                    outbox.acknowledge(id: op.id)
                } catch {
                    // The decision matrix lives in CommentDrainPolicy so it can
                    // be unit-tested; this only maps the transport error onto
                    // the policy's vocabulary.
                    let failure: CommentFailureKind
                    if error is VikunjaAPI.ActivityUnavailable {
                        failure = .notSupported
                    } else if let api = error as? VikunjaAPI.APIError {
                        if api.isGone { failure = .gone }
                        else if api.isRateLimited { failure = .rateLimited }
                        else if api.isAuthFailure { failure = .authFailure }
                        else if api.isClient4xx { failure = .client4xx }
                        else { failure = .transport }
                    } else {
                        failure = .transport
                    }

                    switch CommentDrainPolicy.outcome(for: failure, kind: op.kind) {
                    case .acknowledge:
                        outbox.acknowledge(id: op.id)
                    case .retryable:
                        outbox.markRetryableFailure(id: op.id, message: VeyrnError.message(for: error))
                    case .permanent(let reason):
                        outbox.markPermanentFailure(id: op.id, message: message(for: reason, error: error))
                    case .stopPass:
                        // A throttle is a deferral, not this op's fault, so it
                        // must not consume retry budget.
                        outbox.markDeferred(id: op.id)
                        drainRequestedWhileDraining = false
                        return
                    }
                }
            }
        } while drainRequestedWhileDraining && store.reachability.isOnline
    }

    /// Fails comment ops whose task create has gone away, so they stop looking
    /// like work in progress.
    ///
    /// `eligibleOperations()` filters out every `.client` ref, so such an op can
    /// only ever be sent after a remap — and once the create that would have
    /// produced that remap is gone, no remap can ever arrive. The op would
    /// otherwise sit there forever, counted in the pill, deliverable by nothing.
    ///
    /// It marks rather than deletes, deliberately. The one case where dropping
    /// the text is right is the user discarding the create themselves, and
    /// `discardAny` already acknowledges the children there, under a
    /// confirmation that says the text will be lost. Every other way a create
    /// disappears is a failure the user never agreed to — a 4xx from the task
    /// drain, or `sendBulkCreate` removing ops it could not remap because the
    /// response came back shorter than the request (TaskStore.swift, "even if
    /// the response were somehow shorter"). Acknowledging here would delete
    /// what they wrote on the strength of that, with only a log line. Marked
    /// instead, the text stays visible and copyable in the Pending Changes
    /// sheet.
    private func sweepOrphans() {
        guard let store else { return }
        var swept = 0
        for op in commentOutbox.operations {
            guard case .client(let uuid) = op.taskRef else { continue }
            guard store.outbox.placeholderId(forClient: uuid) == nil else { continue }
            guard op.state != .permanentlyFailed else { continue }
            commentOutbox.markPermanentFailure(
                id: op.id,
                message: String(
                    localized: "The task this update belongs to was never created.",
                    table: "Activity",
                    comment: "Shown for a queued comment whose offline task creation is gone"
                )
            )
            swept += 1
        }
        if swept > 0 {
            DiagnosticLog.warn("comment outbox: \(swept) op(s) stranded — task create is gone")
        }
    }

    /// User-facing wording for a policy decision. Kept here rather than in
    /// `CommentDrainPolicy` so that stays a pure, string-free decision table.
    private func message(for reason: CommentFailureReason, error: Error) -> String {
        switch reason {
        case .ambiguousCreate:
            return String(
                localized: "Not sent. It may already have posted — check the task before retrying.",
                table: "Activity",
                comment: "Shown when a comment request failed with no answer, so it may or may not have been saved"
            )
        case .notSupported:
            return String(
                localized: "This server doesn’t support comments.",
                table: "Activity",
                comment: "Shown when the Vikunja server has no v2 comment API"
            )
        case .server:
            return VeyrnError.message(for: error)
        }
    }

    // MARK: - Housekeeping

    /// `CommentOutbox` is deliberately Foundation-only so the unit-test bundle
    /// can compile it without the Keychain, so it reports load damage as state
    /// instead of logging. Counts only — never comment text.
    private func logLoadIssue() {
        switch commentOutbox.loadIssue {
        case .none:
            break
        case .droppedRecords(let count):
            DiagnosticLog.warn("comment outbox: dropped \(count) malformed record(s)")
        case .unreadable:
            DiagnosticLog.error("comment outbox: payload unreadable, quarantined")
        case .newerSchema(let found):
            DiagnosticLog.error("comment outbox: schema v\(found) is newer than this build; read-only")
        }
    }

    /// Removes account-scoped defaults keys left behind by accounts that no
    /// longer exist.
    ///
    /// Upstream's `VikunjaConfig.deleteAccount` removes the two task-outbox
    /// keys it knows about by name; teaching it the comment outbox meant
    /// editing it. Sweeping here instead costs upstream nothing and is
    /// strictly more thorough: it also cleans up after an account deleted by an
    /// older build, which a fix inside `deleteAccount` never could.
    private func purgeOrphanAccountKeys() {
        let live = Set(VikunjaConfig.accounts.map(\.id.uuidString))
        // An empty list is NOT proof that every account was deleted.
        // `VikunjaConfig.loadAccounts()` returns [] whenever the App Group
        // defaults are unavailable or the stored blob fails to decode, and this
        // runs on every launch and every account switch. Without this guard,
        // one transient read failure deletes every account-scoped key —
        // including `vikunja.outbox.v1.<uuid>`, i.e. task creates and edits
        // that exist nowhere else. There is nothing to sweep with no accounts
        // anyway: the next launch that reads them successfully will do it.
        guard !live.isEmpty else { return }
        let defaults = UserDefaults.standard
        let allKeys = Array(defaults.dictionaryRepresentation().keys)
        var removed = 0
        for key in allKeys {
            guard AccountKeyPurge.prefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            guard let uuid = AccountKeyPurge.accountId(in: key), !live.contains(uuid) else { continue }
            defaults.removeObject(forKey: key)
            removed += 1
        }
        if removed > 0 {
            DiagnosticLog.info("purged \(removed) defaults key(s) from deleted account(s)")
        }
    }
}
