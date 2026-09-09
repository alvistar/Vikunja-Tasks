import XCTest

final class TaskActivityTests: XCTestCase {
    private let formatter = ISO8601DateFormatter()

    /// The projection reads `TaskActivityStamps`, which is decoded straight off
    /// `GET /tasks/{id}`. Build the fixtures from that JSON rather than a
    /// memberwise initialiser, so a rename of a wire key fails the test instead
    /// of silently emptying the timeline in the app.
    private func stamps(
        id: Int = 1,
        created: String? = nil,
        doneAt: String? = nil,
        subtasks: [(id: Int, title: String, doneAt: String?)] = []
    ) throws -> TaskActivityStamps {
        var dict: [String: Any] = ["id": id]
        if let created { dict["created"] = created }
        if let doneAt { dict["done_at"] = doneAt }
        if !subtasks.isEmpty {
            dict["related_tasks"] = ["subtask": subtasks.map { sub -> [String: Any] in
                var s: [String: Any] = ["id": sub.id, "title": sub.title]
                if let d = sub.doneAt { s["done_at"] = d }
                return s
            }]
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(TaskActivityStamps.self, from: data)
    }

    func testProjectsOnlyDirectCompletionAndComments() throws {
        let date = formatter.date(from: "2026-09-04T10:00:00Z")!
        let raw = formatter.string(from: date)
        let parent = try stamps(created: raw, subtasks: [(id: 2, title: "Ship", doneAt: raw)])
        let comment = VikunjaComment(
            id: 3, comment: "Sent", author: VikunjaCommentAuthor(id: 1, name: nil, username: "me"),
            created: raw, updated: raw
        )

        let items = TaskActivityProjection.project(stamps: parent, comments: [comment])

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
    func testDuplicateOverlayServerIdsDoNotTrapTheProjection() throws {
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

        // Must not trap.
        let items = TaskActivityProjection.project(
            stamps: try stamps(created: raw), comments: [comment], overlays: overlays
        )

        XCTAssertFalse(items.isEmpty, "empty items would make the next assertion vacuous")
        XCTAssertFalse(items.contains { $0.commentId == 7 }, "a queued delete tombstones the comment")
    }

    /// A queued edit must render the user's text, not the stale server copy.
    func testUpdateOverlayOverridesTheServerText() throws {
        let raw = formatter.string(from: Date())
        let comment = VikunjaComment(
            id: 7, comment: "stale server text", author: VikunjaCommentAuthor(id: 1, name: nil, username: "me"),
            created: raw, updated: raw
        )
        let overlay = LocalCommentOverlay(
            id: UUID(), taskRef: .server(1), text: "my edit", timestamp: Date(), serverId: 7, state: .pending
        )

        let items = TaskActivityProjection.project(
            stamps: try stamps(created: raw), comments: [comment], overlays: [overlay]
        )
        let row = items.first { $0.commentId == 7 }

        XCTAssertEqual(row?.text, "my edit")
        XCTAssertEqual(row?.localOverlay, overlay)
    }

    /// An unsent comment is the user-visible core of offline support: it must
    /// appear in the timeline before it has any server id.
    func testUnsentCommentIsAppendedAsALocalRow() throws {
        let raw = formatter.string(from: Date())
        let overlay = LocalCommentOverlay(
            id: UUID(), taskRef: .server(1), text: "not sent yet", timestamp: Date(), serverId: nil, state: .pending
        )

        let items = TaskActivityProjection.project(
            stamps: try stamps(created: raw), comments: [], overlays: [overlay]
        )
        let local = items.first { $0.commentId == nil && $0.isComment }

        XCTAssertEqual(local?.text, "not sent yet")
        XCTAssertEqual(local?.id, .localComment(overlay.id))
        XCTAssertEqual(local?.localOverlay, overlay)
    }

    /// A zero `done_at` is Vikunja's "never", not a completion at year 1.
    func testZeroDoneAtProducesNoCompletionRow() throws {
        let raw = formatter.string(from: Date())
        let s = try stamps(created: raw, doneAt: "0001-01-01T00:00:00Z")
        XCTAssertEqual(TaskActivityProjection.project(stamps: s, comments: []).map(\.kind), [.created])
    }

    func testDoneTaskProducesACompletionRow() throws {
        let raw = formatter.string(from: Date())
        let s = try stamps(created: raw, doneAt: raw)
        XCTAssertEqual(
            Set(TaskActivityProjection.project(stamps: s, comments: []).map(\.kind)),
            [.created, .completedTask]
        )
    }

    /// A task that exists only in the outbox has no server stamps at all; the
    /// timeline is then the user's own queued text and nothing else.
    func testNilStampsStillProjectsOverlays() {
        let overlay = LocalCommentOverlay(
            id: UUID(), taskRef: .client(UUID()), text: "queued", timestamp: Date(), serverId: nil, state: .pending
        )
        let items = TaskActivityProjection.project(stamps: nil, comments: [], overlays: [overlay])
        XCTAssertEqual(items.map(\.kind), [.comment])
        XCTAssertEqual(items.first?.text, "queued")
    }
}
