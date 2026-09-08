import XCTest

final class TaskActivityTests: XCTestCase {
    private let formatter = ISO8601DateFormatter()

    func testProjectsOnlyDirectCompletionAndComments() {
        let date = formatter.date(from: "2026-09-04T10:00:00Z")!
        let raw = formatter.string(from: date)
        let completedChild = VikunjaTask(id: 2, title: "Ship", done: true, dueDate: nil, projectId: 1, created: raw, doneAt: raw, relatedTasks: nil)
        let task = VikunjaTask(
            id: 1, title: "Parent", done: false, dueDate: nil, projectId: 1,
            created: raw, relatedTasks: ["subtask": [completedChild]]
        )
        let comment = VikunjaComment(
            id: 3, comment: "Sent", author: VikunjaCommentAuthor(id: 1, name: nil, username: "me"),
            created: raw, updated: raw
        )

        let items = TaskActivityProjection.project(task: task, comments: [comment])

        XCTAssertEqual(items.map(\.kind), [.created, .completedSubtask, .comment])
        XCTAssertFalse(items.contains { $0.text.contains("updated") })
    }

    func testCommentOutboxCoalescesCreateEditAndCancellation() {
        let suite = "VeyrnCoreTests.comments.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())
        let created = outbox.create(taskRef: .server(1), text: "first")

        outbox.update(taskRef: .server(1), serverId: nil, clientCommentId: created.clientCommentId, text: "second")
        XCTAssertEqual(outbox.operations.count, 1)
        XCTAssertEqual(outbox.operations[0].text, "second")

        outbox.delete(taskRef: .server(1), serverId: nil, clientCommentId: created.clientCommentId)
        XCTAssertTrue(outbox.operations.isEmpty)
    }

    /// Pins the crash: two overlays sharing a serverId used to trap
    /// `Dictionary(uniqueKeysWithValues:)` inside `project()`. Because the
    /// overlays come from a queue persisted in UserDefaults, that trap was a
    /// crash on every open of the task, across relaunches, unrecoverable in-app.
    func testDuplicateOverlayServerIdsDoNotTrapTheProjection() {
        let outbox = CommentOutbox(defaults: freshDefaults(), accountId: UUID())
        outbox.delete(taskRef: .server(1), serverId: 7, clientCommentId: UUID())
        outbox.delete(taskRef: .server(1), serverId: 7, clientCommentId: UUID())

        let overlays = outbox.overlays(for: .server(1))
        let task = VikunjaTask(id: 1, title: "T", done: false, projectId: 1)

        // Must not trap.
        let items = TaskActivityProjection.project(task: task, comments: [], overlays: overlays)
        XCTAssertTrue(items.allSatisfy { $0.commentId != 7 }, "a queued delete tombstones the comment")
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "VeyrnCoreTests.projection.\(UUID().uuidString)")!
    }
}
