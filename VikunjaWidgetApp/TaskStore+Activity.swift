import Foundation

// MARK: - Task Activity: TaskStore surface (fork addition)
//
// Everything the Activity feature adds to `TaskStore`'s public surface lives
// here. `TaskStore.swift` is upstream's highest-churn file (25 commits in three
// months), so the feature keeps its distance: it reads upstream state, and the
// only thing upstream's own code has to know about it is that a companion
// object exists.
@MainActor
extension TaskStore {

    // MARK: - Rows for the forked Pending Changes sheet

    /// Upstream's rows plus the queued comments, interleaved chronologically.
    ///
    /// The comments have to be here: they count toward `pendingOperationCount`,
    /// which drives the toolbar pill and the Activity banner's "Review
    /// updates". Listed nowhere, a permanently-failed comment showed as
    /// "N pending" that no retry and no discard could ever clear.
    ///
    /// Upstream's task rows are already in queue order (insertion order), so
    /// sorting by `queuedAt` changes nothing about their presentation.
    var activityPendingRows: [ActivityPendingRow] {
        (pendingChanges.map(ActivityPendingRow.init) + commentPendingRows)
            .sorted { $0.queuedAt < $1.queuedAt }
    }

    private var commentPendingRows: [ActivityPendingRow] {
        commentOutbox.operations.map { op in
            let label: String
            switch op.kind {
            case .create:
                label = String(localized: "Update", table: "Activity", comment: "Pending Changes row: a queued comment on a task")
            case .update:
                label = String(localized: "Edited update", table: "Activity", comment: "Pending Changes row: a queued edit to a comment")
            case .delete:
                label = String(localized: "Deleted update", table: "Activity", comment: "Pending Changes row: a queued comment deletion")
            }
            return ActivityPendingRow(
                id: op.id,
                icon: "text.bubble",
                kindLabel: label,
                taskTitle: activityTitle(for: op.taskRef),
                queuedAt: op.timestamp,
                // Discarding a queued comment drops the text, but never the task.
                deletesTask: false,
                // A delete carries no body worth showing.
                body: {
                    if case .delete = op.kind { return nil }
                    return op.text.isEmpty ? nil : op.text
                }(),
                errorMessage: op.errorMessage,
                canRetry: op.state == .permanentlyFailed || op.state == .retryableFailed,
                isComment: true
            )
        }
    }

    /// Counts for the forked "Discard All" confirmation.
    ///
    /// Upstream's `pendingDiscardSummary` counts only the task outbox, so on a
    /// queue of comments alone the dialog read "This will undo 0 changes" and
    /// then went on to drop them. Comment ops never delete a task, so they are
    /// always `others`.
    var activityDiscardSummary: (creates: Int, others: Int) {
        let base = pendingDiscardSummary
        return (base.creates, base.others + commentOutbox.operations.count)
    }

    /// Reimplementation of upstream's `private func title(for:)`.
    ///
    /// Relaxing that one was the alternative; it is fifteen lines of pure
    /// lookup over `undoneTasks` / `doneTasks` / `outbox`, so a copy costs less
    /// than a fork-shaped requirement on an upstream signature. A miss is
    /// expected — a reopened task is briefly in neither list — so it falls back
    /// to a neutral label and never surfaces a negative placeholder id.
    func activityTitle(for ref: TaskRef) -> String {
        switch ref {
        case .server(let id):
            if let task = undoneTasks.first(where: { $0.id == id })
                ?? doneTasks.first(where: { $0.id == id }) {
                return task.title
            }
            return String(localized: "Task #\(id)", table: "Activity", comment: "Pending Changes row fallback when the task isn't in the loaded lists")
        case .client(let uuid):
            if let placeholderId = outbox.placeholderId(forClient: uuid),
               let task = undoneTasks.first(where: { $0.id == placeholderId })
                ?? doneTasks.first(where: { $0.id == placeholderId }) {
                return task.title
            }
            for op in outbox.ops {
                if case .client(let opUUID) = op.ref, opUUID == uuid,
                   case .create(let payload, _) = op.kind {
                    return payload.title
                }
            }
            return String(localized: "New task", table: "Activity", comment: "Pending Changes row: a queued task creation")
        }
    }

    // MARK: - Discard

    /// Discards a row from either queue. Both id spaces are UUIDs, so a lookup
    /// miss in one is a hit in the other.
    ///
    /// For a task `.create`, the comments queued against it are acknowledged
    /// first: `CommentOutbox.eligibleOperations()` filters out every `.client`
    /// ref, and once the create that would have produced the remap is gone, no
    /// remap can ever arrive. Those ops would sit there forever, counted in the
    /// pill, deliverable by nothing.
    func discardAny(opId: UUID) async {
        if commentOutbox.operations.contains(where: { $0.id == opId }) {
            guard !isDrainingComments else {
                DiagnosticLog.info("discard ignored — comment drain in progress")
                return
            }
            commentOutbox.acknowledge(id: opId)
            DiagnosticLog.info("discarded queued comment op")
            return
        }

        if let op = outbox.ops.first(where: { $0.id == opId }),
           case .create = op.kind, case .client(let uuid) = op.ref,
           !isDraining, !isDrainingComments {
            for commentOp in commentOutbox.operations where commentOp.taskRef == .client(uuid) {
                commentOutbox.acknowledge(id: commentOp.id)
            }
        }

        await discard(opId: opId)
    }

    /// "Discard All" across both queues.
    ///
    /// Upstream's `discardAll()` early-returns on an empty task outbox, so with
    /// only comments queued the button was a no-op and a stuck comment could
    /// not be cleared from anywhere in the app.
    func discardEverything() async {
        guard !isBusy else {
            DiagnosticLog.info("discardAll ignored — drain in progress")
            return
        }
        let queuedComments = commentOutbox.operations
        for commentOp in queuedComments {
            commentOutbox.acknowledge(id: commentOp.id)
        }
        if !queuedComments.isEmpty {
            DiagnosticLog.info("discard all: \(queuedComments.count) queued comment(s)")
        }
        await discardAll()
    }
}
