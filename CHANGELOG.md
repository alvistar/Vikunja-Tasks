# Changelog

All notable changes to this fork are documented here, in the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This fork follows
[Semantic Versioning](https://semver.org/) on its **own** line: the numbers here
are not Scott's. Each release records the upstream commit it sits on, because
the two version lines will drift and only one of them is in this file.

`VERSION` at the repo root is the source of truth. `make gen` writes it into
`Version.xcconfig`, which every target's `MARKETING_VERSION` reads, so the
number in the app's About panel cannot disagree with the number in the repo.
The build number is separate: it lives in `project.yml`
(`CURRENT_PROJECT_VERSION`) and is bumped by hand before an upload.

## [Unreleased]

## [1.0.0] - 2026-09-10

First numbered release of the fork. Everything below is what this fork adds to
or changes in Scott's app; it is not a list of the app's features.

_Based on upstream `3a820a0` — Veyrn 3.4.0, build 96._

### Added

- **Task Activity: server-backed comments.** Read and post comments on a task,
  with an offline outbox that survives a quit and drains on the next launch.
  The whole feature is a build-time plugin: `VEYRN_ACTIVITY` gates it through
  two `#if` seams and ten otherwise-neutral lines, so a build without the flag
  produces Scott's app. Its sources, strings catalog, API surface and wire
  shapes live in their own folders rather than widening upstream's types.
- **One setting for every install identifier.** Bundle id, App Group, keychain
  group and iCloud container all derive from `VEYRN_BUNDLE_PREFIX` in
  `Identifiers.xcconfig`, which optionally includes the git-ignored
  `Signing.xcconfig`. A fork of this fork overrides one line and gets an app
  that coexists with every other build instead of fighting it over the App
  Group, the keychain and the URL scheme. Upstream's values remain the default.
- **Documentation for the fork** (Diataxis): why the fork exists, how to build
  it, how to merge from upstream, and a tutorial for the Activity feature.
- `VERSION` and this changelog.

### Changed

- The Pending Changes sheet is forked rather than edited in place, so upstream
  merges of that file stay clean.
- Activity state lives in a companion observed off `TaskStore` instead of
  inside it.
- The current user is cached per account rather than per view.
- `make gen` now works on a fresh clone with no `Signing.xcconfig`.

### Fixed

- **The task title was clipped.** `NSTextField.intrinsicContentSize` honours
  `preferredMaxLayoutWidth` only under Auto Layout, so inside `sizeThatFits` it
  always reported one line and a wrapped title got 28pt of room for 54pt of
  text. Measured at 442pt: 27.0 before, 54.0 after. macOS only.
- **The task editor opened with a caret in the title.** AppKit hands a freshly
  presented sheet its initial first responder while the window is not key yet;
  the title field now declines it in that window and accepts a click or a Tab
  as before.
- **A missing App Group key failed silently.** On a fork build, a target that
  loses the `VeyrnAppGroup` Info.plist key fell back to upstream's group, which
  that binary is not entitled to — it reads empty rather than erroring, so the
  target looked signed out. The diagnostic log header now says so out loud.
- Data-loss defects in the comment outbox: the orphan sweep and the key purge
  could destroy user data, a failed restore could delete the plugin's only
  copy, and the queue was re-read on each drain pass to stop it misreporting
  the server.
- The discard-all copy rendered its own inflection markup.

### Known gaps

- The Logbook cannot open a task detail.
- `VikunjaWidgetExtension/InfoIOS.plist` is referenced by no target. It is kept
  in sync, but editing it changes nothing — both widget extensions read
  `Info.plist`.
- The fork still reports telemetry under upstream's TelemetryDeck namespace.

[Unreleased]: https://github.com/alvistar/Vikunja-Tasks/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/alvistar/Vikunja-Tasks/releases/tag/v1.0.0
