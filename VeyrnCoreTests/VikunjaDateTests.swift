import XCTest

/// Timestamp parsing is load-bearing for the activity feed in a way that fails
/// silently: `TaskActivityProjection` drops any comment whose `createdDate` is
/// nil, so an unparseable format empties the timeline rather than erroring.
final class VikunjaDateTests: XCTestCase {

    /// The regression that motivated this type. Vikunja's Go backend marshals
    /// RFC3339Nano; a bare ISO8601DateFormatter rejects fractional seconds.
    /// Every fixture in this suite used whole seconds, and the dev instance
    /// happens to emit them too, so nothing caught it.
    func testParsesFractionalSeconds() {
        XCTAssertNotNil(VikunjaDate.parse("2026-09-04T10:17:32.913894+02:00"))
        XCTAssertNotNil(VikunjaDate.parse("2026-09-04T10:17:32.913Z"))
        XCTAssertNotNil(VikunjaDate.parse("2026-09-04T10:17:32.1Z"))
    }

    func testParsesWholeSeconds() {
        XCTAssertNotNil(VikunjaDate.parse("2026-09-04T10:17:32Z"))
        XCTAssertNotNil(VikunjaDate.parse("2026-09-04T10:17:32+02:00"))
    }

    /// Fractional and whole-second spellings of the same instant must agree,
    /// or sorting the timeline would depend on which shape the server used.
    func testBothSpellingsAgreeOnTheInstant() throws {
        let whole = try XCTUnwrap(VikunjaDate.parse("2026-09-04T10:17:32Z"))
        let fractional = try XCTUnwrap(VikunjaDate.parse("2026-09-04T10:17:32.000Z"))
        XCTAssertEqual(whole.timeIntervalSince1970, fractional.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Vikunja writes the zero date for "never" instead of omitting the field.
    func testZeroDateIsNever() {
        XCTAssertNil(VikunjaDate.parse("0001-01-01T00:00:00Z"))
        XCTAssertNil(VikunjaDate.parse("0001-01-01T00:00:00.000Z"))
    }

    func testNilAndGarbage() {
        XCTAssertNil(VikunjaDate.parse(nil))
        XCTAssertNil(VikunjaDate.parse(""))
        XCTAssertNil(VikunjaDate.parse("not a date"))
    }

    /// Exercised through the model accessors, since that is how the projection
    /// reaches them.
    func testCommentAndTaskAccessorsUseTheSharedParser() throws {
        let author = VikunjaCommentAuthor(id: 1, name: nil, username: "me")
        let comment = VikunjaComment(
            id: 1, comment: "c", author: author,
            created: "2026-09-04T10:17:32.913894+02:00", updated: "0001-01-01T00:00:00Z"
        )
        XCTAssertNotNil(comment.createdDate, "a fractional timestamp must not empty the feed")
        XCTAssertNil(comment.updatedDate)

        let json = """
        {"id": 1, "created": "2026-09-04T10:17:32.5Z", "done_at": "2026-09-04T11:00:00.25Z"}
        """
        let stamps = try JSONDecoder().decode(TaskActivityStamps.self, from: Data(json.utf8))
        XCTAssertNotNil(stamps.createdDate)
        XCTAssertNotNil(stamps.doneAtDate)
    }
}
