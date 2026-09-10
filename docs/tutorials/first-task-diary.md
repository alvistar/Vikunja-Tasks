# Tutorial: your first task diary

You will take a task that runs over several days, add dated updates to it as things happen, and end with a timeline that tells you at a glance what happened and when, even after a week away. You will also see the updates survive going offline. By the end you will understand what the Activity card shows, what it deliberately does not show, and where a stuck update goes.

## What you'll need

- A build of the fork on macOS or iOS, signed and connected to your Vikunja account. See [How to build the fork](../how-to/build-the-fork.md).
- A Vikunja server on 2.4.0 or later.
- Ten minutes and a way to turn the network off (Airplane Mode on iOS, Wi-Fi off on a Mac).

## Step 1: create a task and read its first event

1. Press the Quick Add shortcut and type:

   ```text
   Return the faulty router to the ISP tomorrow
   ```

2. Open the task from Scheduled. Below the subtasks card is a card headed **Activity**. Expand it with **Show 1 activity items**.

You see one muted row:

```text
◷ Task created                                   10:03
```

That is the server's `created` timestamp, not the app's clock. The card shows only facts the server can vouch for. Nothing else has happened to this task yet, so nothing else is listed.

## Step 2: add an update

1. Click into **Add an update** at the bottom of the card and type:

   ```text
   Called support. RMA number is **RMA-4471**, label arrives by email.
   ```

2. Press send.

The update appears at the top of the timeline with a small **Sending** chip, which vanishes within a second or two:

```text
alessandro   10:07
Called support. RMA number is RMA-4471, label arrives by email.

◷ Task created                                   10:03
```

The author line shows your Vikunja username. The bold rendered because comments accept inline Markdown. Open the same task in the Vikunja web UI: your update is there as a comment. It is stored on the server, not in the app, so any Vikunja client shows it.

## Step 3: add an update while offline

1. Turn the network off.
2. Add another update:

   ```text
   Label printed. Parcel packed.
   ```

3. Press send.

The update appears immediately with a **Sending** chip, and the pill in the toolbar shows one pending change. Quit the app and reopen it: the update is still there, still pending. It is stored in a queue on disk, alongside Veyrn's other offline changes.

4. Turn the network back on. Within a minute the chip disappears and the pill clears. Check the web UI: both comments are there, in order.

## Step 4: complete a subtask and watch it appear

1. In the subtasks card, add a subtask "Drop parcel at the courier" and check it off.
2. Close the task and open it again. The creation and completion rows are fetched when the task opens.

A new automatic row appears with the server's completion time:

```text
✓ Completed  Drop parcel at the courier          14:20
alessandro   10:07
Called support. RMA number is RMA-4471, label arrives by email.
◷ Task created                                   10:03
```

You did not write that row. The server recorded `done_at` on the subtask, and the timeline reads it. This is the point of the feature: the parts of the story that the server already knows, you never have to type.

## Step 5: fix an update

Suppose the RMA number was wrong.

1. Click the **⋯** on your first update and choose **Edit update**. The text moves into the composer under "Editing your update".
2. Change `RMA-4471` to `RMA-4417` and press **Save update**.

The row updates in place. In the web UI, the comment now shows the corrected text. Only your own comments offer this menu; a comment written by someone else from the web UI shows none.

## Step 6: see where a stuck update goes

1. Turn the network off again and add an update: `Courier picked it up.`
2. Before turning the network back on, click the **⋯** on that pending update and choose **Delete update…**, then confirm.

The row disappears at once and the pill clears. Nothing was ever sent: a delete of an update that has not left the device simply cancels it. Turn the network on and check the web UI. There is no third comment.

Now the case you actually need to know about. If an update fails in a way the app cannot recover from on its own, the card shows a red **Not sent** chip on the row and a banner, **An update needs attention**, with a **Review updates** button. That opens the Pending Changes sheet, where the update is listed with its text and its error, and you choose **Retry** or **Discard**. Your text is never thrown away silently. The [how-to](../how-to/use-task-activity.md#recover-an-update-that-failed) covers each error you might see there.

## What you built

A task that reads as one story. Come back in a week and the Activity card tells you: created on the 3rd, called support on the 3rd, parcel dropped on the 5th, completed when you check it off. The dated updates are yours; the creation and completion rows are the server's; the description stays free for the stable context, such as the account number.

Two things it will not tell you, on purpose. It will not show a row for a due-date or title change made from another client, because Vikunja records only that *something* changed, not what. And it will not invent events the server does not know about. If a row is there, it happened, at that time.

Next:

- [How to use task Activity](../how-to/use-task-activity.md) for editing, deleting, paging and recovery in full.
- [Why this fork exists](../explanation/why-this-fork.md) for why this feature is in a fork and not in the App Store version of Veyrn.
- [Task Activity reference](../reference/task-activity.md) if you want to know exactly what the server calls look like.
