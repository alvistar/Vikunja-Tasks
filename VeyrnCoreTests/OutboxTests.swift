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
}
