# How to build the fork

Build the fork of Veyrn with task Activity enabled, run its unit tests, and prove that the feature can be switched off or removed. At the end you have a signed local build with the Activity card in every task editor.

## Prerequisites

- Everything upstream's README asks for: Xcode 26 or later, `xcodegen` (`brew install xcodegen`), a paid Apple Developer account, and a Vikunja instance with an API token.
- A `Signing.xcconfig` at the repo root with your `DEVELOPMENT_TEAM`. It is git-ignored and not in any checkout. See [the README](../../README.md#3-create-your-signing-config).
- All the identifier changes in [Forking: identifiers you must change](../../README.md#forking-identifiers-you-must-change), if you intend to install alongside the App Store copy of Veyrn. The fork does not change any of those identifiers for you.
- A Vikunja server on **2.4.0 or later** if you want comments. Older servers still get the Activity card with creation and completion rows, but the composer is hidden because comments need API v2.

## Steps

1. Clone the fork, not upstream.

   ```bash
   git clone https://github.com/alvistar/Vikunja-Tasks.git
   cd Vikunja-Tasks
   ```

2. Generate the Xcode project. Always through `make`, never with a bare `xcodegen generate`, which rewrites all six entitlements files as empty plists.

   ```bash
   make gen
   ```

3. Confirm the build flag reached the app target.

   ```bash
   xcodebuild -project VikunjaWidget.xcodeproj -target VikunjaWidgetApp \
     -configuration Debug -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS
   ```

   Expected: `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG VEYRN_ACTIVITY`. If `DEBUG` is missing, `project.yml` has lost the explicit `DEBUG` next to the flag; see the [reference](../reference/task-activity.md#build-switch).

4. Run the unit tests. This is a macOS-only test bundle that compiles the Activity core and the task outbox; it needs no signing and no server.

   ```bash
   xcodebuild test -project VikunjaWidget.xcodeproj -scheme VeyrnCoreTests \
     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   ```

   Expected: `Executed 46 tests, with 0 failures` and `** TEST SUCCEEDED **`.

5. Open the project and build the app you want.

   ```bash
   open VikunjaWidget.xcodeproj
   ```

   Pick `VikunjaWidgetApp` (macOS) or `VikunjaWidgetAppIOS` (iOS), then build and run. The Watch scheme builds too but has no Activity feature.

6. Open any task that exists on the server. The Activity card sits below the subtask card. If the task has no comments and was never completed, it shows "No activity yet" and the "Add an update" composer.

## Verification

- A task with at least one comment in the Vikunja web UI shows that comment in Veyrn's Activity card with the author's name and a dated timestamp.
- Typing an update and pressing send makes it appear in the Vikunja web UI within a few seconds.
- Settings, the toolbar pill and the Pending Changes sheet behave as upstream's, plus queued comments when there are any.

## Optional: prove the plugin can be switched off

Neither of these runs in a normal build. Both are unsigned Debug builds of the macOS app.

```bash
make vanilla       # flag off, Activity files still compiled: the #if seams line up
make uninstalled   # Activity folders moved aside, upstream's tree built, everything restored
```

`make uninstalled` restores the folders and `project.yml` on exit whether the build passed or failed, and prints `✓ plugin restored`. If it prints `✗ RESTORE INCOMPLETE`, your Activity folders are in the temp directory it names; move them back by hand before doing anything else.

## Troubleshooting

**"cannot find 'TaskActivityCompanion' in scope"** in a normal build. The flag is set but the `VikunjaWidgetApp/Activity/` folder is not in the target. Run `make gen` again; xcodegen picks up subfolders automatically, but only when the project is regenerated.

**The Activity card is missing entirely.** Either the flag is unset (check step 3) or you are looking at a task that exists only in the offline outbox and has not been created on the server yet. Local-only tasks show no card until they have a server ID.

**The composer is missing but the card is there.** The server reports an API version below 2.4.0, or the once-per-launch `/info` probe has not landed yet. Pull to refresh; the composer appears once the probe confirms v2.

**The unsigned build crashes on launch.** Expected and documented upstream: without an iCloud entitlement the CloudKit change beacon throws on start. Unsigned builds are compile checks only. Sign to run.

**`make uninstalled` fails to build.** Upstream's tree no longer compiles with the fork's `project.yml`, which usually means a merge from upstream added or removed a file. Fix `project.yml` first; the seam check is only meaningful once upstream's tree builds on its own.

## Related

- [Task Activity reference](../reference/task-activity.md), including the build switch and every make target.
- [How to merge from upstream](merge-from-upstream.md)
- [Why this fork exists](../explanation/why-this-fork.md)
