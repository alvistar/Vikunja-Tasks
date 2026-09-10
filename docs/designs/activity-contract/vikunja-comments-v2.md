# Vikunja v2 Comment Contract

Probed on 2026-09-04 against an isolated task in Inbox. The probe task and its comment were deleted after the check. No token, host, user data, or comment body is recorded here.

## Result

**API contract: PASS** for v2 comment list, create, update, delete, and current-user identity.

| Operation | Request | Result |
|---|---|---|
| List | `GET /tasks/{taskID}/comments` | `200`, page envelope |
| Create | `POST /tasks/{taskID}/comments` body `{ "comment": … }` | `201`, comment object |
| Update | `PUT /tasks/{taskID}/comments/{commentID}` body `{ "comment": … }` | `200`, updated comment object |
| Delete | `DELETE /tasks/{taskID}/comments/{commentID}` | `204`, empty body |
| Current user | `GET /user` | `200`, includes numeric `id` |

## Read Envelope

```json
{
  "items": [/* comments */],
  "page": 1,
  "per_page": 50,
  "total": 0,
  "total_pages": 1
}
```

The server uses page numbers and `total_pages`; the client must implement `CommentPage`, not a cursor.

## Ordering

**The default order is ascending — oldest first.** Verified 2026-09-08 against
Vikunja 2.5.0 on a task holding two comments:

```
GET /tasks/46/comments            -> ids [7, 18]   (created 10:17, then 16:53)
GET ...?sort_by=id&order_by=desc  -> ids [18, 7]
GET ...?page=1&per_page=1         -> ids [7]        total=2 total_pages=2
GET ...?page=2&per_page=1         -> ids [18]
```

The original probe ran against an empty task (`"total": 0`), so it observed no
ordering at all and the client was written assuming page 1 held the newest
comments. It does not. `fetchCommentPage` therefore sends
`sort_by=id&order_by=desc` explicitly, which the server honours, so that page 1
is genuinely the newest page and `hasEarlierPage` / "Load earlier activity"
walk backwards in time as their names claim.

Without that parameter the bug is invisible below 51 comments on a single task,
because one page holds everything.

## Comment Shape

A created/updated comment returns `id`, `comment`, `author`, `created`, `updated`, and `reactions`. The response has no explicit per-comment edit/delete capability field. The client obtains the authenticated numeric user ID from `GET /user` and exposes comment actions only where `comment.author.id == currentUser.id`; server errors remain authoritative.

## Error and Retry Rules

- Mutations stay on v2. They never fall back to v1 or replay through another API version.
- Authentication/rate-limit failures are retryable; validation and permission failures require review; a missing target is terminal.
- The probe did not establish a server idempotency key or searchable client correlation field. An ambiguous create must remain unresolved for explicit user retry/recovery, rather than being automatically replayed.

## Direct Subtask Timestamp

A live task-detail response was previously verified to contain direct `related_tasks.subtask` children with `done_at`; `0001-…` means no completion event.

## Review

- Probe owner / cleanup owner: local Veyrn maintainer.
- This record unblocks version-routed comment transport implementation.
- The separate CommentOutbox schema gate remains open until its migration and round-trip tests exist.
