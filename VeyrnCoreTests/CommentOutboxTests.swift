import XCTest

/// Regression tests for the persistence and coalescing defects found in the
/// pre-landing review. Each test names the failure it pins, because every one
/// of these was silent: nothing threw, nothing logged, and the happy-path UI
/// exercised none of them.
final class CommentOutboxTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "VeyrnCoreTests.commentOutbox.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: - Persistence

    func testRoundTripsEveryKindAndState() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID()

        let outbox = CommentOutbox(defaults: defaults, accountId: account)
        let created = outbox.create(taskRef: .server(1), text: "hello")
        outbox.update(taskRef: .server(1), serverId: 5, clientCommentId: UUID(), text: "edited")
        outbox.delete(taskRef: .server(1), serverId: 6, clientCommentId: UUID())
        outbox.markRetryableFailure(id: created.id, message: "offline")

        let restored = CommentOutbox(defaults: defaults, accountId: account)
        XCTAssertEqual(restored.operations.count, 3)
        XCTAssertEqual(restored.operations.map(\.kind),
                       [.create, .update(serverId: 5), .delete(serverId: 6)])
        XCTAssertEqual(restored.operations[0].state, .retryableFailed)
        XCTAssertEqual(restored.operations[0].errorMessage, "offline")
        XCTAssertEqual(restored.operations[0].text, "hello")
        XCTAssertNil(restored.loadIssue)
    }

    /// The defect: `load()` decoded the whole array at once inside an empty
    /// catch, so ONE malformed record silently discarded every other queued
    /// comment the user had written.
    func testOneMalformedRecordDoesNotDestroyTheRestOfTheQueue() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID()
        let key = "vikunja.commentOutbox.v1.\(account.uuidString)"

        // Build a real envelope with the production encoder, then splice one
        // undecodable record into the middle. Hand-writing the record JSON
        // would test my idea of the on-disk shape rather than the real one.
        let seed = CommentOutbox(defaults: defaults, accountId: account)
        _ = seed.create(taskRef: .server(1), text: "keep me")
        _ = seed.create(taskRef: .server(1), text: "keep me too")

        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: key)))
                as? [String: Any]
        )
        var records = try XCTUnwrap(envelope["operations"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2, "seeding failed; on-disk shape changed")
        records.insert(["id": "not-a-uuid", "text": 42], at: 1)
        envelope["operations"] = records
        defaults.set(try JSONSerialization.data(withJSONObject: envelope), forKey: key)

        let outbox = CommentOutbox(defaults: defaults, accountId: account)
        XCTAssertEqual(outbox.loadIssue, .droppedRecords(1))
        XCTAssertEqual(outbox.operations.count, 2, "good records must survive a bad neighbour")
        XCTAssertEqual(outbox.operations.map(\.text), ["keep me", "keep me too"])
    }

    /// The defect: an unknown newer version returned early leaving `operations`
    /// empty, but the object stayed writable — so the next mutation wrote an
    /// empty v1 envelope over a v2 queue and destroyed it.
    func testNewerSchemaIsReadOnlyAndIsNeverOverwritten() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID()
        let key = "vikunja.commentOutbox.v1.\(account.uuidString)"

        // A real envelope carrying a queued comment, stamped with a version this
        // build does not know — what a downgrade actually looks like.
        let seed = CommentOutbox(defaults: defaults, accountId: account)
        _ = seed.create(taskRef: .server(1), text: "written by a newer build")
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: key)))
                as? [String: Any]
        )
        envelope["version"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: envelope)
        defaults.set(futureData, forKey: key)

        let outbox = CommentOutbox(defaults: defaults, accountId: account)
        XCTAssertEqual(outbox.loadIssue, .newerSchema(found: 99))
        XCTAssertTrue(outbox.isReadOnly)

        // A mutation must not clobber the newer payload.
        _ = outbox.create(taskRef: .server(1), text: "from an older build")
        XCTAssertEqual(defaults.data(forKey: key), futureData,
                       "an older build must not overwrite a newer schema")
    }

    /// The defect: a wholly undecodable payload was swallowed, and the next
    /// persist() overwrote the original bytes — destroying the only copy.
    func testUnreadablePayloadIsQuarantinedNotOverwritten() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID()
        let key = "vikunja.commentOutbox.v1.\(account.uuidString)"
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        defaults.set(garbage, forKey: key)

        let outbox = CommentOutbox(defaults: defaults, accountId: account)
        XCTAssertEqual(outbox.loadIssue, .unreadable)
        XCTAssertTrue(outbox.operations.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "\(key).quarantine"), garbage,
                       "the original bytes must survive for recovery")
    }

    /// `VikunjaConfig.deleteAccount` purges every UserDefaults key that starts
    /// with "vikunja." and contains the account id. It cannot reference this
    /// type (that file also compiles into the watch and widget targets, which
    /// exclude the comment sources), so this test guards the invariant that
    /// purge relies on from the other side of the boundary.
    ///
    /// Without it, an account deletion left the user's unsent comment text in
    /// UserDefaults forever, with no owner left to read or clear it.
    func testEveryPersistedKeyIsReachableByTheAccountPurgeRule() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID()

        // Exercise both write paths: the normal queue, and the quarantine key
        // that an unreadable payload produces.
        let outbox = CommentOutbox(defaults: defaults, accountId: account)
        _ = outbox.create(taskRef: .server(1), text: "unsent")
        let key = "vikunja.commentOutbox.v1.\(account.uuidString)"
        defaults.set(Data([0x00, 0x01]), forKey: key)
        _ = CommentOutbox(defaults: defaults, accountId: account)

        let written = defaults.dictionaryRepresentation().keys
            .filter { $0.contains(account.uuidString) }
        XCTAssertFalse(written.isEmpty, "nothing was persisted; the test proves nothing")

        for key in written {
            XCTAssertTrue(key.hasPrefix("vikunja."),
                          "\(key) escapes the deleteAccount purge prefix")
        }
        XCTAssertEqual(Set(written), Set(CommentOutbox.persistedKeys(accountId: account)),
                       "persistedKeys must stay an accurate inventory of what is written")
    }

    // MARK: - Coalescing

    /// The defect: `delete` displaced only queued `.update` ops, so a second
    /// delete appended a second op for the same serverId. Two overlays with one
    /// serverId then trapped `TaskActivityProjection` on
    /// `Dictionary(uniqueKeysWithValues:)` — a crash on every open of the task,
    /// persisted, with no in-app way out.
    func testRepeatedDeleteLeavesExactlyOneOpPerServerId() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())

        outbox.delete(taskRef: .server(1), serverId: 7, clientCommentId: UUID())
        outbox.delete(taskRef: .server(1), serverId: 7, clientCommentId: UUID())

        XCTAssertEqual(outbox.operations.count, 1)
        let serverIds = outbox.overlays(for: .server(1)).compactMap(\.serverId)
        XCTAssertEqual(serverIds, [7])
        XCTAssertEqual(Set(serverIds).count, serverIds.count, "duplicate serverId would trap the projection")
    }

    /// The other half of the same defect: an update queued after a delete.
    /// It must not resurrect a comment the user deleted, and must not produce
    /// a second op for that serverId either.
    func testUpdateAfterQueuedDeleteIsRefusedRatherThanResurrecting() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())

        outbox.delete(taskRef: .server(1), serverId: 9, clientCommentId: UUID())
        outbox.update(taskRef: .server(1), serverId: 9, clientCommentId: UUID(), text: "back from the dead")

        XCTAssertEqual(outbox.operations.count, 1)
        XCTAssertEqual(outbox.operations[0].kind, .delete(serverId: 9))
    }

    func testRepeatedUpdateCoalescesToTheLatestText() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())

        outbox.update(taskRef: .server(1), serverId: 3, clientCommentId: UUID(), text: "first")
        outbox.update(taskRef: .server(1), serverId: 3, clientCommentId: UUID(), text: "second")

        XCTAssertEqual(outbox.operations.count, 1)
        XCTAssertEqual(outbox.operations[0].text, "second")
    }

    /// Pins the silent no-op: with no serverId and no matching queued create,
    /// the user's edit is discarded. Documented here as intentional so a future
    /// change to it is a deliberate one.
    func testUpdateWithNoServerIdAndUnknownClientIdIsANoOp() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())
        _ = outbox.create(taskRef: .server(1), text: "keep")

        outbox.update(taskRef: .server(1), serverId: nil, clientCommentId: UUID(), text: "lost")
        outbox.delete(taskRef: .server(1), serverId: nil, clientCommentId: UUID())

        XCTAssertEqual(outbox.operations.count, 1)
        XCTAssertEqual(outbox.operations[0].text, "keep")
    }

    // MARK: - Remap and eligibility

    /// `eligibleOperations()` filters out every `.client` ref, so remap is the
    /// only thing that makes a comment on an offline-created task deliverable.
    func testRemapMakesOfflineTaskCommentsEligible() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())
        let client = UUID(), other = UUID()

        _ = outbox.create(taskRef: .client(client), text: "a")
        _ = outbox.create(taskRef: .client(client), text: "b")
        _ = outbox.create(taskRef: .client(other), text: "c")
        XCTAssertTrue(outbox.eligibleOperations().isEmpty)

        outbox.remap(taskClientId: client, toServerId: 77)

        XCTAssertEqual(outbox.eligibleOperations().count, 2)
        XCTAssertEqual(outbox.operations.filter { $0.taskRef == .server(77) }.count, 2)
        XCTAssertEqual(outbox.operations.filter { $0.taskRef == .client(other) }.count, 1,
                       "an unrelated client id must be untouched")
    }

    func testAcknowledgingAnAlreadyRemovedOpIsHarmless() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())
        let created = outbox.create(taskRef: .server(1), text: "oops")

        outbox.delete(taskRef: .server(1), serverId: nil, clientCommentId: created.clientCommentId)
        XCTAssertTrue(outbox.operations.isEmpty)

        outbox.acknowledge(id: created.id)
        outbox.markPermanentFailure(id: created.id, message: "late")
        XCTAssertTrue(outbox.operations.isEmpty)
    }

    func testRefreshBlockingAndFailurePredicatesAreScopedAndStateAware() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = CommentOutbox(defaults: defaults, accountId: UUID())
        let op = outbox.create(taskRef: .server(1), text: "x")

        XCTAssertTrue(outbox.blocksRefresh(for: .server(1)))
        XCTAssertFalse(outbox.blocksRefresh(for: .server(2)), "must be scoped to the task")
        XCTAssertFalse(outbox.hasFailure(for: .server(1)))

        outbox.markPermanentFailure(id: op.id, message: "nope")
        XCTAssertFalse(outbox.blocksRefresh(for: .server(1)), "a dead op must not block refresh forever")
        XCTAssertTrue(outbox.hasFailure(for: .server(1)))
    }
}
