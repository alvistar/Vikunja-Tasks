import XCTest

final class OutboxTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VeyrnCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistsOperationsPerAccount() {
        let account = UUID()
        let op = PendingOp(id: UUID(), timestamp: .now, ref: .server(42), kind: .complete)

        let outbox = Outbox(defaults: defaults, accountId: account)
        outbox.append(op)

        let restored = Outbox(defaults: defaults, accountId: account)
        XCTAssertEqual(restored.ops.count, 1)
        XCTAssertEqual(restored.ops.first?.id, op.id)
    }

    func testRemapChangesEveryMatchingClientReference() {
        let account = UUID()
        let client = UUID()
        let outbox = Outbox(defaults: defaults, accountId: account)
        let create = PendingOp(
            id: UUID(),
            timestamp: .now,
            ref: .client(client),
            kind: .create(
                payload: CreatePayload(
                    title: "Offline task",
                    projectId: 1,
                    description: nil,
                    dueDate: nil,
                    priority: nil,
                    labels: [],
                    reminders: [],
                    repeatAfter: nil,
                    repeatMode: nil
                ),
                placeholderId: -1
            )
        )
        let complete = PendingOp(id: UUID(), timestamp: .now, ref: .client(client), kind: .complete)
        outbox.append(create)
        outbox.append(complete)

        outbox.remap(client: client, toServer: 77)

        XCTAssertEqual(outbox.ops.map(\.ref), [.server(77), .server(77)])
    }

    // MARK: - didRemap (fork addition)

    /// The hook the Activity companion hangs the comment queue off. It replaces
    /// two explicit `commentOutbox.remap(...)` calls that used to sit inside
    /// `TaskStore.drainOutbox`, and it exists because `remap` and `remove`
    /// happen in one synchronous step: after the drain moves on, nothing can
    /// tell that a client id ever became a server id.
    func testDidRemapReportsEveryClientIdItResolves() {
        let outbox = Outbox(defaults: defaults, accountId: UUID())
        let client = UUID()
        var seen: [(UUID, Int)] = []
        outbox.didRemap = { seen.append(($0, $1)) }

        outbox.remap(client: client, toServer: 99)

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, client)
        XCTAssertEqual(seen.first?.1, 99)
    }

    /// Fires even when the task queue holds no op for that client. The bulk
    /// create path removes each op right after remapping it, and a comment can
    /// be queued against a task whose own create op has already been coalesced
    /// away — so gating the callback on a matching op would silently strand
    /// exactly the comments this hook exists to rescue.
    func testDidRemapFiresEvenWithNoMatchingTaskOp() {
        let outbox = Outbox(defaults: defaults, accountId: UUID())
        var fired = false
        outbox.didRemap = { _, _ in fired = true }

        outbox.remap(client: UUID(), toServer: 7)

        XCTAssertTrue(fired, "the comment queue keys off the client id, not off the task op")
    }

    /// End-to-end over the real pair, because the wiring is the part that broke
    /// when it was moved: a comment queued against an offline-created task must
    /// become sendable the moment that task lands. `eligibleOperations()`
    /// filters out every `.client` ref, so without the hook the comment is
    /// undeliverable forever.
    func testHookedCommentQueueFollowsTheRemap() {
        let account = UUID()
        let outbox = Outbox(defaults: defaults, accountId: account)
        let comments = CommentOutbox(defaults: defaults, accountId: account)
        outbox.didRemap = { client, server in
            comments.remap(taskClientId: client, toServerId: server)
        }

        let client = UUID()
        _ = comments.create(taskRef: .client(client), text: "queued while offline")
        XCTAssertTrue(comments.eligibleOperations().isEmpty, "a .client ref is never eligible")

        outbox.remap(client: client, toServer: 4321)

        XCTAssertEqual(comments.operations.first?.taskRef, .server(4321))
        XCTAssertEqual(comments.eligibleOperations().count, 1, "the comment must become sendable")
    }
}
