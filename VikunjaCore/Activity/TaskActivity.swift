import Foundation

enum TaskActivityKind: Int, Comparable {
    case created = 0
    case completedTask = 1
    case completedSubtask = 2
    case comment = 3

    static func < (lhs: TaskActivityKind, rhs: TaskActivityKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TaskActivityItem: Identifiable, Equatable {
    enum Identity: Hashable {
        case automatic(TaskActivityKind, Int)
        case comment(Int)
        case localComment(UUID)
    }

    let id: Identity
    let kind: TaskActivityKind
    let timestamp: Date
    let text: String
    let author: VikunjaCommentAuthor?
    let commentId: Int?
    let localOverlay: LocalCommentOverlay?

    var isComment: Bool { kind == .comment }
}

enum TaskActivityProjection {
    /// `stamps` is nil until `GET /tasks/{id}` lands (and stays nil for a task
    /// that exists only in the outbox), in which case the timeline is comments
    /// and overlays only. That is the correct reading: an unsent task has no
    /// server-side creation event to show.
    static func project(
        stamps: TaskActivityStamps?,
        comments: [VikunjaComment],
        overlays: [LocalCommentOverlay] = []
    ) -> [TaskActivityItem] {
        var items: [TaskActivityItem] = []
        if let stamps {
            if let created = stamps.createdDate {
                items.append(TaskActivityItem(
                    id: .automatic(.created, stamps.id), kind: .created, timestamp: created,
                    text: "Task created", author: nil, commentId: nil, localOverlay: nil
                ))
            }
            if let doneAt = stamps.doneAtDate {
                items.append(TaskActivityItem(
                    id: .automatic(.completedTask, stamps.id), kind: .completedTask, timestamp: doneAt,
                    text: "Task completed", author: nil, commentId: nil, localOverlay: nil
                ))
            }
            for subtask in stamps.subtasks where subtask.id != stamps.id {
                guard let doneAt = subtask.doneAtDate else { continue }
                items.append(TaskActivityItem(
                    id: .automatic(.completedSubtask, subtask.id), kind: .completedSubtask, timestamp: doneAt,
                    text: "Completed \(subtask.title)", author: nil, commentId: nil, localOverlay: nil
                ))
            }
        }
        var deletedServerIds = Set<Int>()
        for overlay in overlays where overlay.state == .deleting {
            if let id = overlay.serverId { deletedServerIds.insert(id) }
        }
        // `uniquingKeysWith`, never `uniqueKeysWithValues`: the latter traps on a
        // duplicate key, and these overlays come from a queue persisted in
        // UserDefaults. A single duplicated serverId would therefore crash this
        // task's activity on every launch, forever, with no in-app way out.
        // CommentOutbox now displaces same-serverId ops so a duplicate should not
        // arise; this is the belt to that suspenders, because the cost of being
        // wrong is unrecoverable for the user.
        let overlaysByServerId = Dictionary(
            overlays.compactMap { overlay in overlay.serverId.map { ($0, overlay) } },
            uniquingKeysWith: { _, latest in latest }
        )
        for comment in comments where !deletedServerIds.contains(comment.id) {
            guard let created = comment.createdDate else { continue }
            let overlay = overlaysByServerId[comment.id]
            items.append(TaskActivityItem(
                id: .comment(comment.id), kind: .comment, timestamp: created,
                text: overlay?.text ?? comment.comment, author: comment.author, commentId: comment.id, localOverlay: overlay
            ))
        }
        for overlay in overlays where overlay.serverId == nil && overlay.state != .deleting {
            items.append(TaskActivityItem(
                id: .localComment(overlay.id), kind: .comment, timestamp: overlay.timestamp,
                text: overlay.text, author: nil, commentId: nil, localOverlay: overlay
            ))
        }
        return items.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return String(describing: lhs.id) < String(describing: rhs.id)
        }
    }
}
