# Documentation

This is the fork of [Veyrn](https://github.com/scottsapps/Vikunja-Tasks) that adds task Activity: Vikunja comments plus a creation and completion timeline, inside the task editor, with offline support. Upstream's own documentation is the [root README](../README.md), which still applies in full.

The documents follow the [Diátaxis](https://diataxis.fr) split. Pick by what you need right now.

## Start here

- [Why this fork exists](explanation/why-this-fork.md): credits to the original author, the upstream decline, what is and is not different.

## Tutorials (learn by doing)

- [Your first task diary](tutorials/first-task-diary.md): create a task, add updates, go offline, watch subtask completions appear.

## How-to guides (get something done)

- [How to use task Activity](how-to/use-task-activity.md): read, add, edit, delete, work offline, recover a stuck update.
- [How to build the fork](how-to/build-the-fork.md): build with the feature on, run the tests, prove it can be switched off.
- [How to merge from upstream](how-to/merge-from-upstream.md): bring in Scott's changes, port the Pending Changes sheet, verify with `make uninstalled`.

## Reference (look something up)

- [Task Activity reference](reference/task-activity.md): build switch, files, wire types, API calls, outbox states, drain policy, view strings, tests.

## Explanation (understand why)

- [Why this fork exists](explanation/why-this-fork.md)
- [Activity architecture](explanation/activity-architecture.md): the compile-time plugin, the companion, the separate outbox, the trade-offs.

## Design history

Written before and during implementation; kept as the record, not maintained as user documentation.

- [`designs/server-backed-task-activity.md`](designs/server-backed-task-activity.md): the approved design and its addenda, including the fork layout and known gaps.
- [`designs/activity-contract/vikunja-comments-v2.md`](designs/activity-contract/vikunja-comments-v2.md): the live probe of Vikunja's v2 comment API.
