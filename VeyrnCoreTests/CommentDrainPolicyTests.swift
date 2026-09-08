import XCTest

/// The decision table that says whether a user's comment is lost, duplicated,
/// or retried forever. It lived inline in `TaskStore.drainCommentOutbox`, which
/// is not compiled into this bundle, so it was the only part of the feature
/// that could not be tested — and it is one misordered branch away from wrong.
final class CommentDrainPolicyTests: XCTestCase {

    private let create = CommentOperationKind.create
    private let update = CommentOperationKind.update(serverId: 1)
    private let delete = CommentOperationKind.delete(serverId: 1)

    /// The whole matrix in one place, so a reordering shows up as a diff.
    func testTheFullMatrix() {
        let expected: [(CommentFailureKind, CommentOperationKind, CommentDrainOutcome)] = [
            (.notSupported, create, .permanent(.notSupported)),
            (.notSupported, update, .permanent(.notSupported)),
            (.notSupported, delete, .permanent(.notSupported)),

            // Deleting something already gone reached the end state the user
            // wanted. Anything else against a gone target is unrecoverable.
            (.gone, delete, .acknowledge),
            (.gone, create, .permanent(.server)),
            (.gone, update, .permanent(.server)),

            (.rateLimited, create, .stopPass),
            (.rateLimited, update, .stopPass),
            (.rateLimited, delete, .stopPass),

            (.authFailure, create, .retryable),
            (.authFailure, update, .retryable),
            (.authFailure, delete, .retryable),

            (.client4xx, create, .permanent(.server)),
            (.client4xx, update, .permanent(.server)),
            (.client4xx, delete, .permanent(.server)),

            // The one asymmetry that matters.
            (.transport, create, .permanent(.ambiguousCreate)),
            (.transport, update, .retryable),
            (.transport, delete, .retryable),
        ]

        for (failure, kind, want) in expected {
            XCTAssertEqual(
                CommentDrainPolicy.outcome(for: failure, kind: kind), want,
                "\(failure) + \(kind)"
            )
        }
    }

    /// Called out separately because getting it wrong posts the user's comment
    /// twice, and the server offers no idempotency key to detect it.
    func testAmbiguousCreateIsNeverRetryable() {
        let outcome = CommentDrainPolicy.outcome(for: .transport, kind: .create)
        XCTAssertEqual(outcome, .permanent(.ambiguousCreate))
        XCTAssertNotEqual(outcome, .retryable, "a create with no answer may already have posted")
    }

    /// A throttle says nothing about this operation, so it must not spend a
    /// retry attempt: five 429s would otherwise permanently fail a valid comment.
    func testRateLimitStopsThePassRatherThanBlamingTheOperation() {
        for kind in [create, update, delete] {
            XCTAssertEqual(CommentDrainPolicy.outcome(for: .rateLimited, kind: kind), .stopPass)
        }
    }

    /// Ordering regression guard: `gone` must be decided before the generic
    /// 4xx bucket, since 404 and 410 are both 4xx.
    func testGoneIsNotSweptIntoTheGeneric4xxBucket() {
        XCTAssertEqual(CommentDrainPolicy.outcome(for: .gone, kind: delete), .acknowledge)
        XCTAssertEqual(CommentDrainPolicy.outcome(for: .client4xx, kind: delete), .permanent(.server))
    }
}

final class AccountKeyPurgeTests: XCTestCase {

    /// The rule missed `veyrn.`-prefixed keys when it was written inline in
    /// `VikunjaConfig`, so `veyrn.projectExpansion.<uuid>` survived account
    /// deletion. Both namespaces are covered now, and this fails if a third
    /// appears.
    func testPurgesEveryNamespaceScopedToTheAccount() {
        let account = UUID()
        let other = UUID()
        let keys = [
            "vikunja.outbox.v1.\(account.uuidString)",
            "vikunja.outbox.placeholderCounter.v1.\(account.uuidString)",
            "vikunja.commentOutbox.v1.\(account.uuidString)",
            "vikunja.commentOutbox.v1.\(account.uuidString).quarantine",
            "veyrn.projectExpansion.\(account.uuidString)",
            // Must survive:
            "vikunja.outbox.v1.\(other.uuidString)",
            "veyrn.projectExpansion.\(other.uuidString)",
            "vikunja.reachability",
            "SomeUnrelatedKey",
        ]

        let purged = Set(AccountKeyPurge.keysToPurge(from: keys, accountId: account))

        XCTAssertEqual(purged, [
            "vikunja.outbox.v1.\(account.uuidString)",
            "vikunja.outbox.placeholderCounter.v1.\(account.uuidString)",
            "vikunja.commentOutbox.v1.\(account.uuidString)",
            "vikunja.commentOutbox.v1.\(account.uuidString).quarantine",
            "veyrn.projectExpansion.\(account.uuidString)",
        ])
        XCTAssertFalse(purged.contains { $0.contains(other.uuidString) },
                       "another account's keys must never be purged")
    }

    /// Cross-checks the rule against what CommentOutbox actually writes,
    /// instead of restating the predicate as a literal in the test.
    func testCoversEveryKeyCommentOutboxWrites() {
        let account = UUID()
        let written = CommentOutbox.persistedKeys(accountId: account)
        XCTAssertFalse(written.isEmpty)
        XCTAssertEqual(
            Set(AccountKeyPurge.keysToPurge(from: written, accountId: account)),
            Set(written),
            "a CommentOutbox key escapes the account purge"
        )
    }
}
