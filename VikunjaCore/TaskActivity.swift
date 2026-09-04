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
    static func project(
        task: VikunjaTask,
        comments: [VikunjaComment],
        overlays: [LocalCommentOverlay] = []
    ) -> [TaskActivityItem] {
        var items: [TaskActivityItem] = []
        if let created = task.createdDate {
            items.append(TaskActivityItem(
                id: .automatic(.created, task.id), kind: .created, timestamp: created,
                text: "Task created", author: nil, commentId: nil, localOverlay: nil
            ))
        }
        if let doneAt = task.doneAtDate {
            items.append(TaskActivityItem(
                id: .automatic(.completedTask, task.id), kind: .completedTask, timestamp: doneAt,
                text: "Task completed", author: nil, commentId: nil, localOverlay: nil
            ))
        }
        for subtask in task.subtasks where subtask.id != task.id {
            guard let doneAt = subtask.doneAtDate else { continue }
            items.append(TaskActivityItem(
                id: .automatic(.completedSubtask, subtask.id), kind: .completedSubtask, timestamp: doneAt,
                text: "Completed \(subtask.title)", author: nil, commentId: nil, localOverlay: nil
            ))
        }
        var deletedServerIds = Set<Int>()
        for overlay in overlays where overlay.state == .deleting {
            if let id = overlay.serverId { deletedServerIds.insert(id) }
        }
        let overlaysByServerId = Dictionary(uniqueKeysWithValues: overlays.compactMap { overlay in
            overlay.serverId.map { ($0, overlay) }
        })
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
