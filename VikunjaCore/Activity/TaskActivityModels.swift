import Foundation

// MARK: - Task Activity: wire shapes (fork addition)
//
// These lived in `VikunjaModels.swift`, which is upstream's shared model file.
// Keeping them here leaves that file byte-identical to upstream, and keeps the
// feature's own `created` / `done_at` needs off `VikunjaTask` — which the
// widget, the Watch and the cache all decode.

struct VikunjaCommentAuthor: Codable, Identifiable, Equatable {
    let id: Int
    let name: String?
    let username: String?
}

struct VikunjaComment: Codable, Identifiable, Equatable {
    let id: Int
    let comment: String
    let author: VikunjaCommentAuthor
    let created: String?
    let updated: String?

    var createdDate: Date? { VikunjaDate.parse(created) }
    var updatedDate: Date? { VikunjaDate.parse(updated) }
}

struct VikunjaCurrentUser: Codable, Identifiable, Equatable {
    let id: Int
    let name: String?
    let username: String?
}

/// The timestamps the Activity timeline draws its automatic rows from, decoded
/// from `GET /tasks/{id}` independently of `VikunjaTask`.
///
/// A separate shape rather than fields on `VikunjaTask`: those fields are only
/// ever read here, but `VikunjaTask` is decoded by the widget, the Watch and
/// the on-disk cache, so widening it makes every one of them carry the
/// feature's schema.
struct TaskActivityStamps: Decodable, Equatable {
    let id: Int
    let created: String?
    /// Vikunja writes the zero date for an incomplete task; use `doneAtDate`.
    let doneAt: String?
    let relatedTasks: [String: [Subtask]]?

    struct Subtask: Decodable, Equatable {
        let id: Int
        let title: String
        let doneAt: String?

        enum CodingKeys: String, CodingKey {
            case id, title
            case doneAt = "done_at"
        }

        var doneAtDate: Date? { VikunjaDate.parse(doneAt) }
    }

    enum CodingKeys: String, CodingKey {
        case id, created
        case doneAt = "done_at"
        case relatedTasks = "related_tasks"
    }

    var createdDate: Date? { VikunjaDate.parse(created) }
    var doneAtDate: Date? { VikunjaDate.parse(doneAt) }
    var subtasks: [Subtask] { relatedTasks?["subtask"] ?? [] }
}

/// Parses the timestamp shapes Vikunja actually emits.
///
/// Two hazards, both silent:
///
/// 1. The Go backend marshals DB timestamps as RFC3339Nano, so a value can
///    carry fractional seconds (`2026-09-04T10:17:32.913894+02:00`). A bare
///    `ISO8601DateFormatter` defaults to `.withInternetDateTime`, which
///    REJECTS those and returns nil — and `TaskActivityProjection` drops any
///    comment whose `createdDate` is nil, so an entire activity feed would
///    render empty while pagination still reported items. Servers that emit
///    whole seconds (this instance, and every test fixture) hide it completely.
///
/// 2. Vikunja writes `0001-01-01T00:00:00Z` for "never" rather than omitting
///    the field, so the zero date must become nil or a task shows as completed
///    in year 1 and sorts to the bottom of the timeline forever.
///
/// The formatters are cached: they were being allocated per property access,
/// which is the expensive part and was paid once per comment per render.
enum VikunjaDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let wholeSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.hasPrefix("0001") else { return nil }
        return fractional.date(from: raw) ?? wholeSeconds.date(from: raw)
    }
}
