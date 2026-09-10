# Why this fork exists

This repository is a fork of [Veyrn](https://github.com/scottsapps/Vikunja-Tasks), the native Vikunja client for macOS, iOS and watchOS written by Scott ([scottsapps](https://github.com/scottsapps)). Everything you like about the app, from the Things 3 layout to the offline outbox and the widgets, is his work. The fork adds exactly one feature on top: **task Activity**, which is Vikunja's task comments plus the task's own creation and completion history, shown as one timeline inside the task editor.

This page explains what the feature is, why it is not in the original app, and how the fork keeps its distance from upstream so that it can keep following Scott's releases.

## Credits

Veyrn is Scott's app. It is published under the [GNU GPL v3](../../LICENSE), which is what makes a fork like this one possible, and it ships on the [App Store](https://apps.apple.com/us/app/veyrn/id6764057920) with beta builds on TestFlight. If you find Veyrn useful, the right place to say thanks is the upstream project and Scott's [Ko-fi](https://ko-fi.com/scott63157), not this fork.

The fork is maintained by Alessandro Viganò ([alvistar](https://github.com/alvistar)). Its home is [github.com/alvistar/Vikunja-Tasks](https://github.com/alvistar/Vikunja-Tasks). It is not distributed on the App Store. You build it yourself, as you would build upstream from source.

## The problem the feature solves

Vikunja supports comments on tasks. The web UI has them, and the API has had them for a long time. Veyrn did not: no comment model, no API calls, no UI and no offline queue for them.

For a task that runs over days or weeks, that gap matters. A parcel that is waiting on a courier, a claim that is waiting on an insurer, a repair with three phone calls behind it: each of those tasks accumulates a history, and the only place to put it in Veyrn was the task description. The description then mixes stable context ("the tracking number is X") with dated updates ("called again on the 4th, they will call back"). Subtasks say what is still to do, but nothing says what already happened and when.

Comments are the natural home for those dated updates. Vikunja stores them with an author and a server timestamp, and the same comments are visible from the Vikunja web UI and from any other client. The fork reads them, lets you write them, and merges them with the facts the server already knows about the task (when it was created, when it and its subtasks were completed) into one chronological story.

```text
Activity                                    Hide activity

  Alessandro  4 Sep 15:20
  Parcel delivered to the pickup point.

  ✓ Completed  Ship the Mac mini            4 Sep 15:19
  ◷ Task created                            1 Sep 10:03

  [ Add an update                              (send) ]
```

## Why upstream declined it

The feature was offered upstream as [pull request #6](https://github.com/scottsapps/Vikunja-Tasks/pull/6) on 2026-09-08. Scott declined it the same day, with a clear reason. Quoting his reply in full, because the reasoning is fair and it defines what the fork is for:

> Thanks for this, but I'm going to decline it as out of scope. Veyrn is deliberately a single-user, due-date-driven task app: put down what needs doing and by when, do it, check it off. Task comments, an in-task activity thread, and an offline comment queue are built around a different workflow — collaboration, or long-running items with an external status thread to keep on top of. For the way Veyrn is used, the logbook already covers finding and reopening completed tasks, and there's no back-and-forth to record, so the Activity card would sit unused on most tasks.
>
> There's one part of the idea I'd be open to in a much smaller form: making the logbook itself better for reconstructing what was done and when — searchable, filterable by date range, that sort of thing. That's self-contained, doesn't touch the task-detail view, and needs no comment API, no offline queue, and no composer. If you wanted to take the PR down to just that, I'd give it a fair read — no commitment to merge, but I'd look properly.

That is a product decision, not a technical one, and it is his to make. Veyrn is a due-date app. The Activity card is for the minority of tasks that carry an external status thread. For most users, most of the time, Scott is right that it would sit unused.

A follow-up, [issue #7](https://github.com/scottsapps/Vikunja-Tasks/issues/7), asked whether upstream would take just the 24 inert lines the fork needs in his files so that the fork stops diverging. He passed on that too, on 2026-09-10, because those lines relax `private` on the API path he is most careful about and add surface with nothing in his tree using it. He offered to keep the seam compiling if one of his changes ever breaks it, and he remains open to a separate Logbook search PR.

So the feature lives here. This fork does not ask upstream for it again.

## What is different from upstream

Only the Activity feature, and the scaffolding needed to carry it. In practice:

- **Two new folders**, `VikunjaCore/Activity/` and `VikunjaWidgetApp/Activity/`, that hold every line of the feature. Neither exists upstream.
- **One build flag**, `VEYRN_ACTIVITY`, set in `project.yml`. With it unset, the two `#if VEYRN_ACTIVITY` blocks in upstream files compile away.
- **Ten neutral lines in five upstream files.** A `didRemap` callback on the outbox, a `pendingOperationCount` indirection in the store, four `private` keywords removed in the API client, and two `#if` blocks. None of them names the feature outside the `#if`.
- **A unit test target**, `VeyrnCoreTests`, with 46 tests. Upstream has no test target.
- **A forked Pending Changes sheet** that also lists queued comments, compiled in place of upstream's file. Upstream's copy stays in the repo, byte-identical, so merges stay clean.
- **Two Makefile targets**, `make vanilla` and `make uninstalled`, that prove the fork can be switched off and removed.

Nothing else changes. Task editing, the widgets, the Watch app, Quick Add, reminders, accounts and the task outbox are upstream's code, unmodified. The Watch app deliberately has no Activity at all: a typical comment on a real instance is around 370 characters, which is far too long for that screen.

The full accounting of what sits in upstream's files, and why each line is there, is in the [Activity architecture](activity-architecture.md) explanation.

## What the fork does not do

- **It does not turn Veyrn into a collaboration tool.** There are no mentions, reactions, attachments or notifications. Comments are a task diary, not a chat.
- **It does not invent history.** The timeline shows only facts with a server timestamp: comments, task creation, task completion and direct-subtask completion. Vikunja's generic `updated` field is deliberately not shown, because it does not say what changed.
- **It does not write to the task description.** The description stays yours. Comments are stored where Vikunja stores them, so the web UI and other clients see the same thing.
- **It does not change how the App Store version behaves.** This is a source-only fork. If you want the official app, install Scott's.

## How the fork tracks upstream

The design goal, adopted after the decline, is that the feature behaves like a **compile-time plugin**: it owns its own files and touches upstream's in as few places as possible. Two folders and a flag install it; removing those three things gives back Scott's tree, and `make uninstalled` builds that tree to prove it.

This keeps merges from upstream cheap. `main` on the fork is periodically rebased onto Scott's `main`; the only file that needs a by-hand check after each merge is `PendingChangesSheet.swift`, because the fork compiles its own copy. The procedure is in [How to merge from upstream](../how-to/merge-from-upstream.md).

## Related

- [Activity architecture](activity-architecture.md): how the feature is built and why it is shaped the way it is.
- [Task Activity reference](../reference/task-activity.md): every type, endpoint, state and build switch.
- [How to use task Activity](../how-to/use-task-activity.md): adding, editing and recovering comments as a user.
- The original design document, written before any code: [`docs/designs/server-backed-task-activity.md`](../designs/server-backed-task-activity.md).
