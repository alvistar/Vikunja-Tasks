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

    /// Pins the crash directly. The earlier version of this test built its
    /// overlays through CommentOutbox, which — now that coalescing is fixed —
    /// produces ONE overlay, so the duplicate case never reached `project()`
    /// and the test could not fail. It also passed `comments: []` against a
    /// dateless task, leaving `items` empty and its assertion vacuous.
    ///
    /// Build the duplicate by hand, and give it a real comment to bite on.
    func testDuplicateOverlayServerIdsDoNotTrapTheProjection() {
        let raw = formatter.string(from: Date())
        let ref = TaskRef.server(1)
        let overlays = [
            LocalCommentOverlay(id: UUID(), taskRef: ref, text: "", timestamp: .now, serverId: 7, state: .deleting),
            LocalCommentOverlay(id: UUID(), taskRef: ref, text: "", timestamp: .now, serverId: 7, state: .deleting),
        ]
        XCTAssertEqual(overlays.compactMap(\.serverId), [7, 7], "the fixture must really contain a duplicate")

        let comment = VikunjaComment(
            id: 7, comment: "server copy", author: VikunjaCommentAuthor(id: 1, name: nil, username: "me"),
            created: raw, updated: raw
        )
        let task = VikunjaTask(id: 1, title: "T", done: false, dueDate: nil, projectId: 1, created: raw, relatedTasks: nil)

        // Must not trap.
        let items = TaskActivityProjection.project(task: task, comments: [comment], overlays: overlays)

        XCTAssertFalse(items.isEmpty, "empty items would make the next assertion vacuous")
        XCTAssertFalse(items.contains { $0.commentId == 7 }, "a queued delete tombstones the comment")
    }

    /// A queued edit must render the user's text, not the stale server copy.
    func testUpdateOverlayOverridesTheServerText() {
        let raw = formatter.string(from: Date())
        let comment = VikunjaComment(
            id: 7, comment: "stale server text", author: VikunjaCommentAuthor(id: 1, name: nil, username: "me"),
            created: raw, updated: raw
        )
        let overlay = LocalCommentOverlay(
            id: UUID(), taskRef: .server(1), text: "my edit", timestamp: Date(), serverId: 7, state: .pending
        )
        let task = VikunjaTask(id: 1, title: "T", done: false, dueDate: nil, projectId: 1, created: raw, relatedTasks: nil)

        let items = TaskActivityProjection.project(task: task, comments: [comment], overlays: [overlay])
        let row = items.first { $0.commentId == 7 }

        XCTAssertEqual(row?.text, "my edit")
        XCTAssertEqual(row?.localOverlay, overlay)
    }

    /// An unsent comment is the user-visible core of offline support: it must
    /// appear in the timeline before it has any server id.
    func testUnsentCommentIsAppendedAsALocalRow() {
        let raw = formatter.string(from: Date())
        let overlay = LocalCommentOverlay(
            id: UUID(), taskRef: .server(1), text: "not sent yet", timestamp: Date(), serverId: nil, state: .pending
        )
        let task = VikunjaTask(id: 1, title: "T", done: false, dueDate: nil, projectId: 1, created: raw, relatedTasks: nil)

        let items = TaskActivityProjection.project(task: task, comments: [], overlays: [overlay])
        let local = items.first { $0.commentId == nil && $0.isComment }

        XCTAssertEqual(local?.text, "not sent yet")
        XCTAssertEqual(local?.id, .localComment(overlay.id))
        XCTAssertEqual(local?.localOverlay, overlay)
    }

    /// A zero `done_at` is Vikunja's "never", not a completion at year 1.
    func testZeroDoneAtProducesNoCompletionRow() {
        let raw = formatter.string(from: Date())
        let task = VikunjaTask(
            id: 1, title: "T", done: false, dueDate: nil, projectId: 1,
            created: raw, doneAt: "0001-01-01T00:00:00Z", relatedTasks: nil
        )
        XCTAssertEqual(TaskActivityProjection.project(task: task, comments: []).map(\.kind), [.created])
    }

    func testDoneTaskProducesACompletionRow() {
        let raw = formatter.string(from: Date())
        let task = VikunjaTask(
            id: 1, title: "T", done: true, dueDate: nil, projectId: 1,
            created: raw, doneAt: raw, relatedTasks: nil
        )
        XCTAssertEqual(
            Set(TaskActivityProjection.project(task: task, comments: []).map(\.kind)),
            [.created, .completedTask]
        )
    }
}
