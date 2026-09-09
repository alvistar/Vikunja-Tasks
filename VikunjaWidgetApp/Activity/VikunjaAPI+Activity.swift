import Foundation

// MARK: - Task Activity: server API (fork addition)
//
// Everything the Activity feature needs from the Vikunja API lives here rather
// than in `VikunjaCore/VikunjaAPI.swift`, which is a high-churn upstream file.
// The only thing left upstream is four `private` → `internal` relaxations on
// plumbing this extension calls (`v2BaseURL`, `supportsAPIv2`, `makeRequest`,
// `send`) — one word each, and the same treatment `supportsBulkTaskCreate`
// already carries there.
//
// Duplicating that plumbing instead was considered and rejected: `send` alone
// carries the sleep/wake retry rule, the `networkConnectionLost` retry, the
// error tiering and the 304 handling — ~140 lines that would drift silently the
// first time upstream fixed a transport bug.
extension VikunjaAPI {

    /// Comments are a v2-only endpoint. Exposed so the UI can hide the composer
    /// and the activity feed rather than letting the user write an update that
    /// can never be delivered on an older server.
    static var supportsComments: Bool { supportsAPIv2 }

    /// Thrown when the server has no v2 API at all.
    ///
    /// Deliberately *not* upstream's `V2NotAvailable`, which is `private` and
    /// means the same thing for the logbook search: relaxing that one would put
    /// a fork-shaped requirement on an upstream type. The drain has to be able
    /// to tell "this server can never answer" from a transient failure — caught
    /// as retryable it would be re-sent every 60 s forever while blocking the
    /// task's activity refresh the whole time.
    struct ActivityUnavailable: Error {}

    /// Our own copy of upstream's `private struct V2Page`. Two decodable
    /// structs with the same three fields is cheaper than a fifth relaxation on
    /// a type upstream may well reshape.
    struct ActivityPage<T: Decodable>: Decodable {
        let items: [T]?
        let page: Int?
        let totalPages: Int?

        enum CodingKeys: String, CodingKey {
            case items, page
            case totalPages = "total_pages"
        }
    }

    struct CommentPage: Equatable {
        let items: [VikunjaComment]
        let page: Int
        let totalPages: Int

        var hasEarlierPage: Bool { page < totalPages }
    }

    // MARK: - v2 request wrappers

    private static func activityGet<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, _) = try await send(makeRequest(path, base: v2BaseURL))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func activityPost<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let (data, _) = try await send(makeRequest(path, method: "POST", body: body, base: v2BaseURL))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func activityPut(_ path: String, body: Data) async throws {
        _ = try await send(makeRequest(path, method: "PUT", body: body, base: v2BaseURL))
    }

    private static func activityDelete(_ path: String) async throws {
        _ = try await send(makeRequest(path, method: "DELETE", base: v2BaseURL))
    }

    // MARK: - Task comments (v2 only, verified against Vikunja 2.6)

    static func fetchCommentPage(taskId: Int, page: Int = 1, perPage: Int = 50) async throws -> CommentPage {
        guard supportsAPIv2 else { throw ActivityUnavailable() }
        // `sort_by=id&order_by=desc` is load-bearing, not a nicety. The server's
        // default order is ASCENDING (verified 2026-09-08 against Vikunja 2.5.0:
        // ids came back [7, 18], oldest first). Without this, page 1 is the
        // OLDEST 50 comments — the collapsed Activity row would show the newest
        // of the oldest page instead of the task's latest activity, and "Load
        // earlier activity" would walk toward newer. Only visible past 50
        // comments on one task, which is why nothing caught it.
        let path = "/tasks/\(taskId)/comments?per_page=\(perPage)&page=\(page)&sort_by=id&order_by=desc"
        let decoded: ActivityPage<VikunjaComment> = try await activityGet(path, as: ActivityPage<VikunjaComment>.self)
        return CommentPage(
            items: decoded.items ?? [],
            page: decoded.page ?? page,
            totalPages: max(1, decoded.totalPages ?? 1)
        )
    }

    static func createComment(taskId: Int, comment: String) async throws -> VikunjaComment {
        guard supportsAPIv2 else { throw ActivityUnavailable() }
        let body = try JSONEncoder().encode(["comment": comment])
        return try await activityPost("/tasks/\(taskId)/comments", body: body, as: VikunjaComment.self)
    }

    /// Returns nothing: the drain only needs to know the write landed, and the
    /// server echo was decoded and discarded at every call site.
    static func updateComment(taskId: Int, commentId: Int, comment: String) async throws {
        guard supportsAPIv2 else { throw ActivityUnavailable() }
        let body = try JSONEncoder().encode(["comment": comment])
        try await activityPut("/tasks/\(taskId)/comments/\(commentId)", body: body)
    }

    static func deleteComment(taskId: Int, commentId: Int) async throws {
        guard supportsAPIv2 else { throw ActivityUnavailable() }
        try await activityDelete("/tasks/\(taskId)/comments/\(commentId)")
    }

    /// The timestamps the Activity timeline needs, from the same
    /// `GET /tasks/{id}` the editor already issues for subtasks — decoded into
    /// our own shape so `VikunjaTask` never has to carry `created`/`done_at`.
    static func fetchActivityStamps(taskId: Int) async throws -> TaskActivityStamps {
        guard supportsAPIv2 else { throw ActivityUnavailable() }
        return try await activityGet("/tasks/\(taskId)", as: TaskActivityStamps.self)
    }

    static func fetchCurrentUser() async throws -> VikunjaCurrentUser {
        guard supportsAPIv2 else { throw ActivityUnavailable() }
        return try await activityGet("/user", as: VikunjaCurrentUser.self)
    }
}
