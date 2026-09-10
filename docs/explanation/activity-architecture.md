# Activity architecture

The task Activity feature adds server-backed comments and a creation/completion timeline to Veyrn's task editor. This page explains how it is built and, more importantly, why it is shaped the way it is. Two constraints drove almost every decision:

1. **Upstream declined the feature**, so it must live in a fork that stays cheap to rebase onto Scott's `main`. See [Why this fork exists](why-this-fork.md).
2. **Comments must work offline**, like everything else in Veyrn, without ever losing or duplicating what the user typed.

For the exact types, endpoints and states, see the [Task Activity reference](../reference/task-activity.md).

## The problem

Three things go wrong with the obvious implementation.

**Editing upstream's files.** The first version of the feature changed nine upstream files by +645/−19 lines, including the three highest-churn files in the repo (`TaskStore.swift` alone has 25 commits in three months). Every upstream release became a merge with conflicts in code that upstream would never see or maintain.

**Widening the task outbox.** Veyrn already has a durable outbox for task operations, `PendingOp`. Adding comment cases to it looks natural, but `Outbox` decodes its whole persisted array with `try?`. One malformed comment record would make the entire array undecodable and silently discard every queued *task* edit along with it.

**Retrying a comment create.** Update and delete are idempotent against a known comment ID, so replaying them converges. A create is not. If a `POST` times out, the comment may already be on the server. The Vikunja API offers no idempotency key and no client correlation field to check, so an automatic retry posts the comment twice.

## The approach

### A compile-time plugin

A runtime plugin is impossible on iOS and watchOS, so "plugin" here means the feature owns its files and touches upstream's in as few places as possible.

```text
 upstream tree (Scott's)                   fork additions
 ─────────────────────────                 ──────────────────────────────────
 VikunjaCore/                              VikunjaCore/Activity/
   Outbox.swift        ← +7 (didRemap)       TaskActivityModels.swift
   VikunjaAPI.swift    ← 4× private→internal TaskActivity.swift
   ...                                       CommentOutbox.swift
                                             CommentDrainPolicy.swift
 VikunjaWidgetApp/                           AccountKeyPurge.swift
   TaskStore.swift     ← +8 (#if + count)  VikunjaWidgetApp/Activity/
   InlineTaskEditor    ← +3 (#if)            TaskActivityCompanion.swift
   AppRoot.swift       ← 2 lines             TaskStore+Activity.swift
   PendingChangesSheet ← excluded, not edited VikunjaAPI+Activity.swift
                                             TaskActivityView.swift
 project.yml           ← flag + test target  PendingChangesSheet.swift (fork copy)
                                             Activity.xcstrings
                                           VeyrnCoreTests/
```

Installing the plugin is two folders and one flag, `VEYRN_ACTIVITY`. Removing them gives back upstream's tree; `make uninstalled` does exactly that and builds it, which is the claim the fork actually makes.

xcodegen adds subfolders to a target automatically, so the two app targets pick up `VikunjaWidgetApp/Activity/` with no `project.yml` line, and the watch targets' explicit `includes:` lists keep ignoring `VikunjaCore/Activity/`.

### The companion object

Everything the feature needs to remember at runtime (the comment queue, the current user's identity, whether the server supports comments) lives in `TaskActivityCompanion`, a `@MainActor @Observable` singleton reached as `store.activity`. It is a companion rather than an extension because an extension cannot add stored properties, and a singleton because `TaskStore` itself is built exactly once.

The companion couples to upstream by **observing** rather than by being called:

```text
  TaskStore (upstream)                    TaskActivityCompanion (fork)
  ────────────────────                    ───────────────────────────
  isDraining: true → false  ───────────▶  drain the comment queue
  isLoading:  true → false  ───────────▶  re-read capabilities, fetch /user
  outbox replaced (account switch) ────▶  reset per-account state
  outbox.didRemap(client, server) ─────▶  remap comments on that task
```

The falling edge of `isDraining` is the important one. `drainOutbox()` raises the flag before checking whether its queue is empty, so every drain trigger upstream already has (the 60 s poll, reachability, scene activation, "Try Again") produces the edge. The comment pass therefore runs after every task drain, and necessarily *after* an offline-created task has received its server ID, so its comments can be delivered. One `attach(to:)` call at the end of `TaskStore.init`, inside the `#if`, is the only wiring upstream carries.

### A separate, versioned comment outbox

`CommentOutbox` is its own persisted store, keyed per account under `vikunja.commentOutbox.v1.<accountUUID>`, with a version envelope. It decodes each record independently, so one malformed record is dropped and counted rather than taking the queue with it. If the whole payload is unreadable, or was written by a newer schema, the bytes are copied to a quarantine key and the queue refuses to overwrite them.

Each queued operation references its task by `TaskRef`, either `.server(id)` or `.client(uuid)` for a task that only exists in the task outbox so far. Only `.server` refs are eligible to send. When the task outbox remaps a client UUID to a server ID, `didRemap` carries the mapping across and the comments become eligible on the next pass.

### The projection

`TaskActivityProjection.project(stamps:comments:overlays:)` is a pure function. It takes the task's timestamps, the server comments and the local overlays from the queue, and returns one sorted list. It performs no network or SwiftUI work, which is what makes it unit-testable and reusable by a future cross-task activity stream.

```text
 GET /tasks/{id}   ──▶ TaskActivityStamps ─┐
 GET /tasks/{id}/comments ──▶ [VikunjaComment] ─┼──▶ project() ──▶ [TaskActivityItem]
 CommentOutbox.overlays(for:) ──▶ [Overlay] ─┘        sorted newest first
```

The sort is deterministic: timestamp descending, then kind (`created`, `completedTask`, `completedSubtask`, `comment`), then stable ID. Overlays do three things: a queued edit substitutes the comment's text, a queued delete hides the comment, and an unsent create appears as a local row with a "Sending" chip.

### The drain policy as a decision table

Which failures are terminal, which are retryable, and which stop the pass is the code that decides whether a user's comment is lost, duplicated or retried forever. It used to live inline in the drain, where nothing could test it, because neither `TaskStore` nor `VikunjaAPI` compiles into the test bundle.

`CommentDrainPolicy.outcome(for:kind:)` is that logic extracted as a pure function over an abstract failure kind. The drain maps the transport error onto the vocabulary; the policy decides; all 18 failure-by-kind combinations are asserted in tests.

## Trade-offs

**Ten lines in upstream files, not zero.** Four `private` keywords on the API client's `send`, `makeRequest`, `v2BaseURL` and `supportsAPIv2` had to become `internal`. Duplicating that plumbing instead was considered and rejected: `send` alone carries the sleep/wake retry rule, the connection-lost retry, error tiering and 304 handling, around 140 lines that would drift the first time upstream fixed a transport bug. Upstream declined to take these relaxations, so the fork carries them and re-checks them on every merge.

**A forked Pending Changes sheet.** Comment operations count toward the toolbar pill, so they had to appear in the sheet or a failed one would show as "1 pending" forever with nothing to clear it. Editing upstream's sheet meant +55/−8 lines of permanent conflict surface. Instead the fork compiles its own copy under the same type names and excludes upstream's file from the app targets. The cost is that a wording or layout change upstream makes over there is invisible until someone diffs it after a merge. A changed *field* still breaks the build, so it cannot go unnoticed.

**An ambiguous create is never retried automatically.** When a comment `POST` fails with no HTTP answer, the operation is marked permanently failed with `mayHavePosted` set, and the user is told to check the task before retrying. Even editing such a comment does not put it back in the queue. This is deliberately less convenient than a silent retry, and it is the only correct behaviour given an API with no idempotency key.

**Retries are bounded.** A retryable failure gives up after five attempts and surfaces a banner. Without the ceiling, a 403 on someone else's comment would be re-sent on every poll forever with no banner, because only permanent failures raise one. The known cost, recorded in the design doc, is that an expired token also burns the budget, and after re-login each comment needs a manual Retry.

**`vanilla` is not feature-free.** `make vanilla` unsets the flag but leaves the Activity files in the target, so it proves only that the `#if` seams still compile. A Debug build's symbols are all still in `Veyrn.debug.dylib`. For the real proof, use `make uninstalled`.

**Hard-coded English in three automatic rows.** "Task created", "Task completed" and "Completed <title>" are the only user-visible strings in the feature that reach no string catalog, because `VikunjaCore/Activity` compiles into the Foundation-only test target. Recorded as a known gap.

## Alternatives considered

From the design document written before any code:

- **Timeline computed inside the editor view.** Fastest to build, but the projection and its ordering would be coupled to SwiftUI, and a later cross-task activity stream would have to duplicate it. Rejected.
- **Field-level audit trail in the Vikunja server.** Would give complete cross-client history, including due-date and title changes made elsewhere. It is a separate upstream project in a different codebase. Deferred.
- **Showing generic `updated` rows.** Rejected as noise: the timestamp has no field-level explanation, so a row saying "updated" tells the reader nothing they can act on.

After the decline, one more:

- **Sending the 24-line seam upstream as a standalone PR.** Offered in issue #7, declined. The fork carries the lines.

## Related

- [Why this fork exists](why-this-fork.md)
- [Task Activity reference](../reference/task-activity.md)
- [How to build the fork](../how-to/build-the-fork.md) and [How to merge from upstream](../how-to/merge-from-upstream.md)
- Design history: [`docs/designs/server-backed-task-activity.md`](../designs/server-backed-task-activity.md) and the live API probe in [`docs/designs/activity-contract/vikunja-comments-v2.md`](../designs/activity-contract/vikunja-comments-v2.md)
