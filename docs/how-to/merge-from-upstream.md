# How to merge from upstream

Bring Scott's latest `main` into the fork without losing the Activity feature, and prove that both the fork and upstream's tree still build afterwards. You end with a fork `main` that contains every upstream commit plus the plugin.

## Prerequisites

- A clone of the fork with two remotes. In this repo they are named `origin` for upstream and `fork` for the fork, which is the opposite of what most tools assume. Check before pushing anything:

  ```bash
  git remote -v
  # fork    https://github.com/alvistar/Vikunja-Tasks (fetch)
  # origin  https://github.com/scottsapps/Vikunja-Tasks (fetch)
  ```

- A working build of the fork before you start, so a failure afterwards is attributable to the merge. See [How to build the fork](build-the-fork.md).
- The commit of the previous merge base, for the sheet diff in step 5. Get it before merging:

  ```bash
  git merge-base origin/main HEAD
  ```

  Note the hash; call it `<previous-base>` below.

## Steps

1. Fetch upstream and merge it.

   ```bash
   git fetch origin main
   git merge origin/main
   ```

   Conflicts, if any, are confined to the five seam files and `project.yml`. The Activity folders do not exist upstream and never conflict.

2. Resolve the seams. Each is a few lines and its exact expected shape is in the [reference](../reference/task-activity.md#seams-in-upstream-files). In particular:

   - `VikunjaCore/VikunjaAPI.swift`: `v2BaseURL`, `supportsAPIv2`, `makeRequest` and `send` must not be `private`. Upstream may well have re-added the keyword or renamed one of them.
   - `VikunjaCore/Outbox.swift`: `didRemap?(uuid, id)` must still be the last statement of `remap(client:toServer:)`.
   - `VikunjaWidgetApp/TaskStore.swift`: the `#if VEYRN_ACTIVITY` block must still be at the end of `init`, after `observeReachability()`.
   - `VikunjaWidgetApp/InlineTaskEditor.swift`: the `#if` block must still sit between the subtask card and the footer hairline.
   - `VikunjaWidgetApp/AppRoot.swift`: both `OfflinePill` calls must read `store.pendingOperationCount`.

3. Resolve `project.yml`. The fork's lines are in four contiguous blocks, each headed `# ── Fork addition (Activity plugin)`: the `settings.configs` flag, the `VeyrnCoreTests` scheme, the `VeyrnCoreTests` target, and the two `PendingChangesSheet.swift` `excludes` lines inside the app targets' source lists. If upstream renamed a file that the test target's `includes:` lists, update the list.

4. Regenerate and build the fork.

   ```bash
   make gen
   xcodebuild test -project VikunjaWidget.xcodeproj -scheme VeyrnCoreTests \
     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   ```

   Then build `VikunjaWidgetApp` and `VikunjaWidgetAppIOS` in Xcode.

5. Port the Pending Changes sheet. The fork compiles its own copy of this file and excludes upstream's, so upstream changes there do not break the build by themselves; they are simply not present. Diff what changed:

   ```bash
   git diff <previous-base>..origin/main -- VikunjaWidgetApp/PendingChangesSheet.swift
   ```

   Apply anything non-trivial by hand to `VikunjaWidgetApp/Activity/PendingChangesSheet.swift`. A changed field on `PendingChange` will already have broken step 4, because `TaskStore.pendingChanges` builds the forked type. A changed layout or wording will not, which is why this step exists.

6. Prove that upstream's tree still builds with the fork's project file.

   ```bash
   make uninstalled
   ```

   Expected: a green build and `✓ plugin restored`. This is the check that the fork has not quietly become dependent on something upstream removed.

7. Run the app against a real server and open a task with comments. Add one update, edit it, delete it.

8. Commit the merge, and push to the fork, never to upstream.

   ```bash
   git push fork main
   ```

## Verification

- `git log --oneline origin/main..HEAD` lists only fork commits.
- `git diff --stat origin/main..HEAD` touches only the two `Activity/` folders, `VeyrnCoreTests/`, `docs/`, `Makefile`, `project.yml`, `README.md` and the five seam files, and the seam files show the expected small line counts (about +7, +8, +3, 4 changed and 2 changed).
- The 46 unit tests pass and `make uninstalled` is green.

## Troubleshooting

**`make uninstalled` fails on a file upstream added.** Upstream's new file may reference `pendingOperationCount` or another seam by its old name, or the test target's `includes:` may now list a file that moved. Fix `project.yml` and re-run.

**`private` came back on one of the four API members.** Remove it again and mention it in the merge commit. Scott has said he will keep the seam compiling if his change breaks it, so an issue upstream is appropriate when the break is more than a keyword.

**The `#if` block in `TaskStore.init` is gone.** A three-way merge can drop it when upstream rewrote the surrounding lines. Re-add it as the last statement of `init`; the companion's `attach(to:)` must run after `observeReachability()`.

**Debug builds lost `DEBUG`.** `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in `project.yml` must read `$(inherited) DEBUG VEYRN_ACTIVITY` for Debug. Upstream does not have this block, so a merge cannot change it, but a hand-edit can.

**You pushed to `origin` by mistake.** That is Scott's repository. You will not have write access, so the push is refused, but check `git remote -v` before every push.

## Related

- [Activity architecture](../explanation/activity-architecture.md), for why the seams are where they are.
- [Task Activity reference](../reference/task-activity.md)
- [Why this fork exists](../explanation/why-this-fork.md)
