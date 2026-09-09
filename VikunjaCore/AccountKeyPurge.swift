import Foundation

/// Which `UserDefaults` keys belong to one account, so deleting that account
/// can remove all of them.
///
/// This exists as its own testable function because the enumerate-them-by-hand
/// version rotted silently: `deleteAccount` listed the two task-outbox keys and
/// was never updated when the comment outbox was added, so a deleted account's
/// unsent comment text stayed on disk with no owner left to read or clear it.
///
/// Replacing that list with a prefix rule then rotted a second time in the same
/// edit — the rule matched only `vikunja.`, while the current naming convention
/// is `veyrn.` (`veyrn.projectExpansion.<uuid>`), so the "fix" missed a key
/// that already existed. Both prefixes are named here, in one place, with a
/// test that fails if an account-scoped key escapes them.
enum AccountKeyPurge {
    /// Every namespace this app writes account-scoped keys under. A new
    /// namespace has to be added here; the test asserts the set covers what
    /// the outboxes actually write.
    static let prefixes = ["vikunja.", "veyrn."]

    /// Account-scoped keys are identified by carrying the account UUID in the
    /// key itself. A per-account key that does NOT is invisible to this rule —
    /// which is a reason to keep putting the uuid in the key.
    static func keysToPurge(from keys: some Sequence<String>, accountId: UUID) -> [String] {
        let id = accountId.uuidString
        return keys.filter { key in
            key.contains(id) && prefixes.contains { key.hasPrefix($0) }
        }
    }

    /// The account UUID embedded in a key, if it carries one.
    ///
    /// The inverse of `keysToPurge`, and what lets the sweep run without being
    /// told which account died: any key naming an account that no longer exists
    /// is an orphan. That also cleans up after accounts deleted by an older
    /// build, which a fix inside `deleteAccount` never could.
    static func accountId(in key: String) -> String? {
        // A UUID string is 36 characters and always follows a "." separator in
        // these keys. Scanning the components is cheaper and less brittle than
        // a regular expression, and rejects anything that is not a real UUID.
        for component in key.split(separator: ".") where component.count == 36 {
            if let uuid = UUID(uuidString: String(component)) {
                return uuid.uuidString
            }
        }
        return nil
    }
}
