# How to use task Activity

Read a task's history, add and edit updates, work offline, and recover an update that failed to send. This is the user-facing guide to the fork's one feature.

## Prerequisites

- A build of the fork on macOS or iOS. See [How to build the fork](build-the-fork.md). The Watch app has no Activity feature.
- A Vikunja server on 2.4.0 or later for comments. On an older server you can read the timeline but not write updates.
- A task that already exists on the server. A task created offline shows its Activity card only after it has synced.

## Read a task's history

1. Open a task from the Inbox, Scheduled or a project list. The **Activity** card is below the subtasks.
2. The card opens collapsed, showing only the most recent event. Click **Show N activity items** to expand it, or **Hide activity** to collapse it again. The choice is remembered while the task stays open.
3. Read newest to oldest. Automatic rows are muted single lines: "Task created", "Task completed", "Completed <subtask>". Comment rows carry the author, the text and a timestamp.
4. A long comment is clamped to four lines. Click **Show more** to read all of it.
5. If the task has more than 50 comments, **Load earlier activity** appears at the bottom and fetches the next older page.

Timestamps are precise on purpose: a bare time means today, "Yesterday 14:32" means yesterday, and anything older carries its day. There are no relative labels such as "18 min ago".

**A completed task cannot be opened from the Logbook**, so its timeline cannot be read there. This is upstream behaviour, recorded as a known gap. Reopen the task from the Logbook to read its Activity, then complete it again.

## Add an update

1. Type in the **Add an update** field at the bottom of the card. It grows to three lines before it scrolls.
2. Press the send button, or Return on macOS. Return submits only when the field has text.
3. The update appears at the top of the timeline immediately with a **Sending** chip. The chip disappears when the server acknowledges it.

Markdown works: `**bold**`, `_italic_` and links render inline.

## Edit or delete your own update

Only comments you wrote show actions. Ownership is decided by comparing the comment's author with the account's user; a comment from another Vikunja user shows no menu.

- Click the **⋯** button on the comment (labelled "More actions for your update" for VoiceOver) and choose **Edit update** or **Delete update…**.
- On iOS you can also swipe a comment to the left to reveal **Edit** and **Delete**.

Editing moves the text into the composer under an "Editing your update" label. Change it and press **Save update**, or **Cancel** to keep the original. Deleting asks "Delete this update?" and warns that it removes the comment for everyone on the task.

You can edit or delete an update that has not been sent yet. An edit rewrites the queued text; a delete cancels the queued send outright, and nothing reaches the server.

## Work offline

Nothing changes in how you use the card. Updates you add, edit or delete while offline are queued alongside Veyrn's other pending changes, survive restarting the app, and are sent when the connection returns. While queued they show a **Sending** or **Removing** chip, and the toolbar pill counts them with your other pending changes.

Comments on a task you created offline wait until the task itself has synced, then follow it.

## Recover an update that failed

An update that cannot be delivered shows a red **Not sent** chip, and the card shows a banner: **An update needs attention** with a **Review updates** button.

1. Click **Review updates**, or tap the pending pill in the toolbar. The **Pending Changes** sheet opens with every queued change, comments included. A queued comment row shows its text and the error.
2. Choose **Retry** to send it again, or **Discard** to drop it. Discarding a comment never deletes the task.
3. **Try Again** at the bottom retries every failed change, tasks and comments alike. **Discard All** drops all of them, after a confirmation that counts the comments.

Two errors deserve care:

- **"Not sent. It may already have posted — check the task before retrying."** The request went out and no answer came back, so the comment may be on the server already. Refresh the task (close and reopen it) and look. If the comment is there, discard the queued copy. If it is not, retry. This case is never retried automatically, because a retry could post the comment twice.
- **"This server doesn't support comments."** The server has no API v2. Discard the update; nothing can deliver it.

An update that failed for a transient reason is retried automatically up to five times across the app's normal sync cycles, then gives up and shows the banner. After you have fixed the cause (for example, re-entered an expired token in Settings), use **Retry** or **Try Again**.

## Verification

- After adding an update, refresh the task in the Vikunja web UI. The comment is there with your username.
- After editing, the web UI shows the new text.
- After deleting, the comment is gone from the web UI.
- After adding an update in Airplane Mode, the pill shows one pending change; leave Airplane Mode and the chip clears within a minute.

## Troubleshooting

**The composer is not there.** The server is below 2.4.0, or the app has not yet confirmed the server version this launch. Refresh; if it stays hidden, check the server version at `https://your-server/api/v1/info`.

**My own comment shows no ⋯ menu.** The app failed to fetch your user identity from `GET /user`. It retries on the next refresh; pull to refresh.

**A comment I deleted is still visible with "Not sent".** The delete gave up. The comment is still live on the server, so the app shows it rather than pretend it is gone. Retry from Pending Changes.

**The card says "Couldn't load newer activity".** The comment fetch failed. Existing rows stay; click **Retry**.

**Activity is empty but the web UI has comments.** Comments with an unparseable timestamp are dropped. Report it with **Settings → Report a Bug** and attach the diagnostic log; the log contains no comment text.

## Related

- [Task Activity reference](../reference/task-activity.md): every state and string.
- [Tutorial: your first task diary](../tutorials/first-task-diary.md)
- [Why this fork exists](../explanation/why-this-fork.md)
