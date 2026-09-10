# Task Activity reference

The complete technical surface of the fork's Activity feature: the build switch, the files, the wire types, the API calls, the comment queue and its states, the drain policy, the strings and the tests. Every item here is traceable to code on the `main` branch of the fork. For the reasoning behind the shape, read [Activity architecture](../explanation/activity-architecture.md).

## Build switch

| Setting | Where | Value |
|---|---|---|
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (Debug) | `project.yml`, project-level `settings.configs` | `$(inherited) DEBUG VEYRN_ACTIVITY` |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (Release) | same | `$(inherited) VEYRN_ACTIVITY` |

`DEBUG` is spelled out, not inherited: xcodegen's Debug preset writes `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` into the same slot, so a value here replaces it, and `$(inherited)` resolves against `Signing.xcconfig`, which does not define it.

The flag reaches every target, including the widgets and the Watch. That is harmless: no file they compile contains `#if VEYRN_ACTIVITY`.

Verify after `make gen`:

```bash
xcodebuild -project VikunjaWidget.xcodeproj -target VikunjaWidgetApp \
  -configuration Debug -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS
# SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG VEYRN_ACTIVITY
```

### Seams in upstream files

The only places the feature is referenced from upstream code.

| File | Change |
|---|---|
| `VikunjaWidgetApp/TaskStore.swift` | `#if VEYRN_ACTIVITY TaskActivityCompanion.shared.attach(to: self) #endif` at the end of `init`; `extraPendingCount` closure and `pendingOperationCount` computed property |
| `VikunjaWidgetApp/InlineTaskEditor.swift` | `#if VEYRN_ACTIVITY TaskActivityView(task: task).padding(.top, 16) #endif` below the subtask card |
| `VikunjaWidgetApp/AppRoot.swift` | Two `store.outbox.ops.count` reads become `store.pendingOperationCount` |
| `VikunjaCore/Outbox.swift` | `var didRemap: ((UUID, Int) -> Void)?`, called at the end of `remap(client:toServer:)` |
| `VikunjaCore/VikunjaAPI.swift` | `v2BaseURL`, `supportsAPIv2`, `makeRequest`, `send` changed from `private` to `internal` |

### Make targets

| Target | Effect |
|---|---|
| `make vanilla` | Debug build of `VikunjaWidgetApp` with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` (flag off). Activity files still compile into the target. Proves the `#if` seams line up. |
| `make uninstalled` | Moves both `Activity/` folders aside, drops the two `PendingChangesSheet.swift` excludes from `project.yml`, runs `make gen`, builds upstream's tree, then restores everything on exit (pass or fail). Leaves build products uninstalled. |

Both require an unsigned build (`CODE_SIGNING_ALLOWED=NO`) and neither is run by a normal build.

## Files

### `VikunjaCore/Activity/` (shared, also in the test target)

| File | Contents |
|---|---|
| `TaskActivityModels.swift` | `VikunjaCommentAuthor`, `VikunjaComment`, `VikunjaCurrentUser`, `TaskActivityStamps`, `VikunjaDate` |
| `TaskActivity.swift` | `TaskActivityKind`, `TaskActivityItem`, `TaskActivityProjection` |
| `CommentOutbox.swift` | `CommentOperationState`, `CommentOperationKind`, `PendingCommentOperation`, `LocalCommentOverlay`, `CommentOutboxLoadIssue`, `CommentOutbox` |
| `CommentDrainPolicy.swift` | `CommentFailureKind`, `CommentFailureReason`, `CommentDrainOutcome`, `CommentDrainPolicy` |
| `AccountKeyPurge.swift` | `AccountKeyPurge` |

### `VikunjaWidgetApp/Activity/` (macOS and iOS app targets only)

| File | Contents |
|---|---|
| `VikunjaAPI+Activity.swift` | `extension VikunjaAPI`: comment and user endpoints, `ActivityUnavailable`, `ActivityPage`, `CommentPage` |
| `TaskActivityCompanion.swift` | `TaskActivityCompanion`: queue ownership, observation of `TaskStore`, the drain |
| `TaskStore+Activity.swift` | `extension TaskStore`: `activity`, `activityPendingRows`, `isBusy`, `retryAll()`, `retryComment(opId:)`, `activityDiscardSummary`, `activityTitle(for:)`, `discardAny(opId:)`, `discardEverything()` |
| `TaskActivityView.swift` | `TaskActivityView`: the timeline, composer, banners, menus and iOS swipe |
| `PendingChangesSheet.swift` | Fork copy of upstream's sheet, compiled instead of `VikunjaWidgetApp/PendingChangesSheet.swift`, adds comment rows |
| `Activity.xcstrings` | String catalog, table name `Activity` |

The Watch targets compile neither folder.

## Wire types

All in `TaskActivityModels.swift`. Timestamps are strings on the wire and parsed through `VikunjaDate`.

```swift
struct VikunjaCommentAuthor: Codable, Identifiable, Equatable {
    let id: Int
    let name: String?
    let username: String?
}

struct VikunjaComment: Codable, Identifiable, Equatable {
    let id: Int
    let comment: String        // Markdown / HTML body as stored by Vikunja
    let author: VikunjaCommentAuthor
    let created: String?
    let updated: String?
    var createdDate: Date?     // VikunjaDate.parse(created)
    var updatedDate: Date?
}

struct VikunjaCurrentUser: Codable, Identifiable, Equatable {
    let id: Int
    let name: String?
    let username: String?
}

struct TaskActivityStamps: Decodable, Equatable {
    let id: Int
    let created: String?
    let doneAt: String?        // "done_at"
    let relatedTasks: [String: [Subtask]]?   // "related_tasks"
    var subtasks: [Subtask]    // relatedTasks?["subtask"] ?? []
    struct Subtask { let id: Int; let title: String; let doneAt: String? }
}
```

`TaskActivityStamps` is decoded from the same `GET /tasks/{id}` the editor already issues, into its own shape, so `VikunjaTask` (decoded by the widgets, the Watch and the on-disk cache) never has to carry `created` or `done_at`.

### `VikunjaDate.parse(_:)`

```swift
static func parse(_ raw: String?) -> Date?
```

- Accepts RFC 3339 with or without fractional seconds. Vikunja's Go backend emits nanosecond precision (`2026-09-04T10:17:32.913894+02:00`), which a bare `ISO8601DateFormatter` rejects.
- Returns `nil` for `nil`, for unparseable input, and for any value starting with `0001` (Vikunja's zero date, meaning "never").
- Formatters are cached statics.

## API

All in `VikunjaAPI+Activity.swift`, all **v2 only**, all `static` on `VikunjaAPI`. Every call throws `VikunjaAPI.ActivityUnavailable` when `supportsAPIv2` is false. There is no v1 fallback for any of them, and mutations are never replayed through another API version.

| Function | Request | Returns |
|---|---|---|
| `fetchCommentPage(taskId:page:perPage:)` | `GET /tasks/{id}/comments?per_page={50}&page={1}&sort_by=id&order_by=desc` | `CommentPage` |
| `createComment(taskId:comment:)` | `POST /tasks/{id}/comments` body `{"comment": …}` | `VikunjaComment` (HTTP 201) |
| `updateComment(taskId:commentId:comment:)` | `PUT /tasks/{id}/comments/{cid}` body `{"comment": …}` | nothing (HTTP 200, echo discarded) |
| `deleteComment(taskId:commentId:)` | `DELETE /tasks/{id}/comments/{cid}` | nothing (HTTP 204) |
| `fetchActivityStamps(taskId:)` | `GET /tasks/{id}` | `TaskActivityStamps` |
| `fetchCurrentUser()` | `GET /user` | `VikunjaCurrentUser` |

Defaults: `page = 1`, `perPage = 50`.

`sort_by=id&order_by=desc` is required. The server's default order is ascending (oldest first, verified against Vikunja 2.5.0), so without it page 1 would hold the oldest comments and "Load earlier activity" would walk toward newer. The bug is invisible below 51 comments on one task.

```swift
static var supportsComments: Bool   // == supportsAPIv2

struct CommentPage: Equatable {
    let items: [VikunjaComment]
    let page: Int
    let totalPages: Int            // max(1, server value)
    var hasEarlierPage: Bool       // page < totalPages
}
```

**Ownership.** The API returns no per-comment permission field. Edit and delete controls are shown only when `comment.author.id == currentUser.id`. Server errors remain authoritative.

The live probe that established this contract is recorded in [`docs/designs/activity-contract/vikunja-comments-v2.md`](../designs/activity-contract/vikunja-comments-v2.md).

## The projection

```swift
enum TaskActivityKind: Int, Comparable { case created = 0, completedTask = 1, completedSubtask = 2, comment = 3 }

struct TaskActivityItem: Identifiable, Equatable {
    enum Identity: Hashable { case automatic(TaskActivityKind, Int); case comment(Int); case localComment(UUID) }
    let id: Identity
    let kind: TaskActivityKind
    let timestamp: Date
    let text: String
    let author: VikunjaCommentAuthor?
    let commentId: Int?
    let localOverlay: LocalCommentOverlay?
    var isComment: Bool
}

enum TaskActivityProjection {
    static func project(stamps: TaskActivityStamps?, comments: [VikunjaComment],
                        overlays: [LocalCommentOverlay] = []) -> [TaskActivityItem]
}
```

Rules:

- `stamps == nil` (the `GET /tasks/{id}` has not landed, or the task exists only in the outbox) yields comments and overlays only.
- One `created` row when `stamps.createdDate` is non-nil. One `completedTask` row when `stamps.doneAtDate` is non-nil. One `completedSubtask` row per direct subtask with a non-nil `doneAtDate`, text `"Completed <title>"`. Grandchildren are not visited.
- Comments whose `createdDate` is nil are dropped.
- A comment with a queued `.delete` overlay (state `.deleting`) is omitted. A comment with a queued `.update` overlay takes the overlay's text; an empty overlay text (a failed delete) leaves the server text intact.
- Overlays with no `serverId` and state other than `.deleting` become `.localComment` rows.
- Sort: `timestamp` descending, then `kind` ascending, then `String(describing: id)` ascending.
- Overlays are keyed by `serverId` with `uniquingKeysWith` (latest wins), never `uniqueKeysWithValues`, so a duplicated ID in persisted state cannot trap.

## The comment outbox

`CommentOutbox` is `@Observable`, Foundation-only, and persisted in `UserDefaults`.

| Item | Value |
|---|---|
| Key | `vikunja.commentOutbox.v1.<accountUUID>` (or `vikunja.commentOutbox.v1` with no account) |
| Quarantine key | `<key>.quarantine` |
| Schema version | `1` (envelope `{version, operations}`) |
| `maxRetryAttempts` | `5` |

### Types

```swift
enum CommentOperationState: String, Codable { case pending, retryableFailed, permanentlyFailed }
enum CommentOperationKind: Codable { case create; case update(serverId: Int); case delete(serverId: Int) }

struct PendingCommentOperation: Codable, Identifiable {
    let id: UUID                 // operation id
    let clientCommentId: UUID    // identity of the comment while it has no server id
    var taskRef: TaskRef         // .server(Int) or .client(UUID)
    var text: String             // "" for a delete
    var kind: CommentOperationKind
    var state: CommentOperationState
    var errorMessage: String?
    let timestamp: Date
    var attempts: Int?           // optional so pre-field records still decode
    var mayHavePosted: Bool?     // set on an ambiguous create
}

struct LocalCommentOverlay: Identifiable {
    enum State { case pending; case retryableFailed(String?); case permanentlyFailed(String?); case deleting }
    let id: UUID; let taskRef: TaskRef; let text: String; let timestamp: Date
    let serverId: Int?; let state: State
}

enum CommentOutboxLoadIssue { case droppedRecords(Int); case unreadable; case newerSchema(found: Int) }
```

### Methods

| Method | Behaviour |
|---|---|
| `init(defaults:accountId:)` | Loads from the account's key. |
| `static persistedKeys(accountId:)` | The key and its quarantine key. |
| `create(taskRef:text:)` | Appends a `.pending` `.create`. |
| `update(taskRef:serverId:clientCommentId:text:)` | If a queued create matches `clientCommentId`, rewrites its text in place and, unless `mayHavePosted`, resets it to `.pending` with `attempts = 0`. Otherwise, if `serverId` is given and no delete is queued for it, displaces other queued ops on that id and appends a `.update`. Silently no-ops when a delete is queued or when `serverId` is nil with no matching create. |
| `delete(taskRef:serverId:clientCommentId:)` | Removes a matching queued create outright. Otherwise displaces queued ops on `serverId` and appends a `.delete` with empty text. |
| `convertCreateToUpdate(id:serverId:)` | Turns a queued create into `.update(serverId)`, `.pending`, `attempts = 0`. Used when the create landed but the text changed in flight. |
| `remap(taskClientId:toServerId:)` | Rewrites every `.client(uuid)` ref to `.server(id)`. |
| `markRetryableFailure(id:message:)` | Increments `attempts`; state becomes `.permanentlyFailed` at `>= 5`, else `.retryableFailed`. |
| `markPermanentFailure(id:message:mayHavePosted:)` | State `.permanentlyFailed`; optionally sets `mayHavePosted`. |
| `markDeferred(id:)` | Back to `.pending`, `attempts` untouched. |
| `retry(id:)` | `attempts = 0`, `.pending`, error cleared. |
| `acknowledge(id:)` | Removes the operation. |
| `eligibleOperations()` | Ops in `.pending` or `.retryableFailed` whose `taskRef` is `.server`. |
| `overlays(for:)` | Overlays for one task. A `.delete` maps to `.deleting` unless permanently failed, in which case `.permanentlyFailed` so the still-live comment is not hidden. |
| `blocksRefresh(for:)` | True when any op for the task is `.pending`. |
| `hasFailure(for:)` | True when any op for the task is `.permanentlyFailed`. |
| `isReadOnly` | True after loading a newer schema; `persist()` becomes a no-op. |
| `loadIssue` | What `load()` found wrong, if anything. |

### State machine

```text
                  create/update/delete
                          │
                          ▼
   ┌──────────────── pending ◀──────────────────────┐
   │                  │  │                          │
   │  server OK       │  │ retryable failure        │ retry(id:) / markDeferred
   │                  │  │ (attempts < 5)           │
   ▼                  │  ▼                          │
 removed ◀────────────┘ retryableFailed ────────────┤
 (acknowledge)            │                         │
                          │ attempts >= 5           │
                          ▼                         │
                    permanentlyFailed ──────────────┘
                     (also: notSupported, gone on
                      create/update, any other 4xx,
                      ambiguous create → mayHavePosted)
```

Refresh of a task's activity is blocked only by `.pending`. A `.retryableFailed` op does not block, because its overlay already shadows the server copy.

## The drain policy

`CommentDrainPolicy.outcome(for: CommentFailureKind, kind: CommentOperationKind) -> CommentDrainOutcome`

Failure kinds, mapped by the companion from the transport error:

| `CommentFailureKind` | Source |
|---|---|
| `.notSupported` | `VikunjaAPI.ActivityUnavailable` |
| `.gone` | `APIError.isGone` (404, 410) |
| `.rateLimited` | `APIError.isRateLimited` (429) |
| `.authFailure` | `APIError.isAuthFailure` (401, 403) |
| `.client4xx` | any other `APIError.isClient4xx` |
| `.transport` | everything else: timeout, dropped connection, proxy 5xx |

Decision table:

| Failure | `.create` | `.update` | `.delete` |
|---|---|---|---|
| `.notSupported` | permanent (notSupported) | permanent (notSupported) | permanent (notSupported) |
| `.gone` | permanent (server) | permanent (server) | **acknowledge** |
| `.rateLimited` | stopPass | stopPass | stopPass |
| `.authFailure` | retryable | retryable | retryable |
| `.client4xx` | permanent (server) | permanent (server) | permanent (server) |
| `.transport` | **permanent (ambiguousCreate)** | retryable | retryable |

- `stopPass` ends the whole drain pass without consuming the operation's retry budget.
- `permanent(.ambiguousCreate)` sets `mayHavePosted` on the operation. Such an op never re-enters the drain by itself, not even after an edit; only an explicit user Retry sends it again.

## The companion

`TaskActivityCompanion.shared`, reached as `store.activity`.

| Member | Purpose |
|---|---|
| `commentOutbox: CommentOutbox` | The current account's queue. Replaced on account switch. |
| `isDraining: Bool` | True during a comment drain pass. |
| `supportsComments: Bool` | Observable mirror of `VikunjaAPI.supportsComments`, refreshed after each task refresh. |
| `currentUser: VikunjaCurrentUser?` | Cached per account; fetched after each refresh until it succeeds. |
| `attach(to:)` | Called once from `TaskStore.init`. Installs `extraPendingCount`, hooks `didRemap`, starts observation, purges orphan keys, drains once. |
| `queueComment(task:text:)` | Queue a create and drain. |
| `queueCommentUpdate(task:commentId:clientCommentId:text:)` | Queue an edit and drain. `commentId` is nil for a not-yet-sent comment. |
| `queueCommentDelete(task:commentId:clientCommentId:)` | Queue a delete and drain. |
| `retryComment(opId:)` | Clear the ceiling on one op and drain. |
| `retryAllFailed()` | Clear the ceiling on every `.permanentlyFailed` op. |
| `acknowledgeAll() -> Int` | Remove every op; returns the count. |
| `acknowledgeChildren(ofClientTask:)` | Remove ops whose parent task create is being discarded. |
| `drain()` | One or more passes over `eligibleOperations()`. Collapses concurrent requests. Requires `reachability.isOnline`. |

Drain triggers: `attach` (once per launch), every falling edge of `TaskStore.isDraining`, and every queue call above.

Drain details worth knowing:

- Each pass re-reads `commentOutbox`, and addresses the instance it started with across its awaits, so an account switch mid-drain never sends the old account's text to the new host.
- After a successful create, the op is re-read: if it was removed in flight the new server comment is deleted; if its text changed in flight the op is converted to an update against the new ID; otherwise it is acknowledged.
- Before each drain, `sweepOrphans()` marks as permanently failed any `.client`-ref op whose task create no longer exists in the task outbox, with the message "The task this update belongs to was never created." The text is kept, not deleted.
- `purgeOrphanAccountKeys()` removes `vikunja.*` and `veyrn.*` defaults keys carrying a UUID of an account that no longer exists. It is skipped when the account list reads back empty, so a transient read failure cannot delete live queues.

## `AccountKeyPurge`

```swift
enum AccountKeyPurge {
    static let prefixes = ["vikunja.", "veyrn."]
    static func keysToPurge(from keys: some Sequence<String>, accountId: UUID) -> [String]
    static func accountId(in key: String) -> String?
}
```

A key is account-scoped when it starts with one of the prefixes and contains the account UUID as a dot-separated 36-character component.

## `TaskStore` additions

In `TaskStore+Activity.swift`, all `@MainActor`.

| Member | Purpose |
|---|---|
| `activity` | `TaskActivityCompanion.shared` |
| `activityPendingRows: [PendingChange]` | Upstream's task rows plus comment rows, sorted by `queuedAt`. Comment rows use icon `text.bubble`, labels "Update" / "Edited update" / "Deleted update", `isComment: true`. |
| `isBusy` | `isDraining || activity.isDraining` |
| `retryAll()` | `retryAllFailed()` then `drainOutbox()`; the comment drain follows on the falling edge. |
| `retryComment(opId:)` | Forwards to the companion. |
| `activityDiscardSummary` | Upstream's counts plus every queued comment as "others". |
| `activityTitle(for:)` | Task title for a `TaskRef`, falling back to "Task #N" or "New task". |
| `discardAny(opId:)` | Discards from either queue. Discarding a task create first acknowledges its queued comments. Refused during a comment drain. |
| `discardEverything()` | Both queues. Refused while `isBusy`. |

## The view

`TaskActivityView(task:)`, placed below the subtask card in `InlineTaskEditor` for tasks with `id > 0` or a client ref.

| Element | Behaviour |
|---|---|
| Header | "Activity" plus a "Show N activity items" / "Hide activity" button. Collapsed shows the latest item only. |
| Loading | "Loading activity…" until the first fetch resolves. |
| Empty | "No activity yet. Comments and completed subtasks appear here." |
| Paging | "Load earlier activity" while `hasEarlierPage`. Pages merge by comment ID, latest wins. |
| Composer | Text field "Add an update" (or "Edit your update"), multi-line, send button labelled "Add update" / "Save update". Hidden when the server has no v2 API. Text is preserved on failure. |
| Comment body | Rendered as inline Markdown, clamped to four lines with "Show more" / "Show less". |
| Chips | "Sending" (pending), "Not sent" (failed), "Removing" (delete queued). |
| Own comments | Ellipsis menu, label "More actions for your update", with "Edit update" and "Delete update…". iOS adds a trailing swipe with Edit and Delete. |
| Delete confirmation | "Delete this update?" with body "This removes it for everyone on the task." |
| Failure banner | "An update needs attention" with "Review updates", which opens the Pending Changes sheet. |
| Fetch failure | "Couldn't load newer activity" or "Couldn't load earlier activity" with "Retry"; on a server without v2, "This server doesn't support comments." with no retry. |
| Timestamps | Bare time today, "Yesterday 14:32", otherwise "4 Sep 14:32", with the year once it differs. Never relative ("18 min ago"). |

Known gap: editing after "Load earlier activity" reloads page 1 only, so on a task with more than 50 comments the paged-in range is dropped from view until reloaded.

## Strings

All user-facing strings of the feature are in `VikunjaWidgetApp/Activity/Activity.xcstrings`, table `Activity`, except the three automatic-row texts in `TaskActivity.swift` ("Task created", "Task completed", "Completed <title>"), which are hard-coded English because that file compiles into the Foundation-only test target.

## Tests

Target `VeyrnCoreTests` (macOS, XCTest), scheme `VeyrnCoreTests`. It compiles `VeyrnCoreTests/` plus these `VikunjaCore` files: `Outbox.swift`, `TaskMerger.swift`, `VikunjaModels.swift` and the five `Activity/` files. Neither `TaskStore` nor `VikunjaAPI` is in the bundle.

```bash
xcodebuild test -project VikunjaWidget.xcodeproj -scheme VeyrnCoreTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

| File | Tests | Covers |
|---|---|---|
| `CommentDrainPolicyTests.swift` | 8 | the full 18-cell decision matrix, `AccountKeyPurge` |
| `CommentOutboxTests.swift` | 19 | persistence, lenient decoding, quarantine, newer schema, coalescing, ceiling, retry, refresh predicates |
| `OutboxTests.swift` | 5 | per-account persistence, `remap`, `didRemap` |
| `TaskActivityTests.swift` | 8 | projection ordering, overlays, zero dates, nil stamps |
| `VikunjaDateTests.swift` | 6 | fractional and whole seconds, zero date, garbage |

46 tests in total. All pass on the current `main` (verified 2026-09-10).

## Related

- [Activity architecture](../explanation/activity-architecture.md)
- [How to build the fork](../how-to/build-the-fork.md)
- [How to use task Activity](../how-to/use-task-activity.md)
- [How to merge from upstream](../how-to/merge-from-upstream.md)
