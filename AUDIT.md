# Honeycrisp — Audit & Fix Patch Series (2026-08-09)

Two passes, 7 commits total, all fixing issues found in the prior audit
pass. Every patch applies cleanly with `git am` (or the combined patch with
`git apply`) directly against the tree as uploaded — no rebasing needed.

## How to apply

```bash
# Option A: full series, in order, as separate commits
git am pass-1-docs-and-build/*.patch
git am pass-2-bug-fixes/*.patch

# Option B: one shot, as a working-tree diff (no commits created)
git apply 00-combined-all-fixes.patch
```

## Pass 1 — docs & build (3 commits, no behavior change)

1. **`docs: fix stale REVISION_PLAN.md reference in ARCHITECTURE.md`**
   §6 pointed at a `REVISION_PLAN.md` that doesn't exist anywhere in the
   repo. Points at `docs/honeycrisp-settings-window-plan.md` instead.
2. **`docs: fix stale window.title comment in ReaderViewController.swift`**
   Header comment claimed `window.title` "stays empty" — no longer true
   since the HIG-cleanup fix `ARCHITECTURE.md` already credits as done.
3. **`fix(build): correct Package.swift source path and project name`**
   `path: "Honeycrisp/Sources"` pointed at a directory that doesn't exist
   (that folder only has `Info.plist`); real sources are top-level
   `Sources/`. `swift build`/`swift package describe` via the SPM entry
   point failed outright before this fix. Also fixed a stale
   `EPUBReader.xcodeproj` → `Honeycrisp.xcodeproj` reference in the same
   file's header comment.

## Pass 2 — functional bug fixes (4 commits)

4. **`fix(history): preserve saved reading position across HistoryManager.record()`**
   The headline bug from the audit. `record()` is called on every book open,
   before `ReaderViewController` reads `savedPosition(for:)` — and `record()`
   used to rebuild the `HistoryEntry` from scratch, defaulting
   `lastSpineIndex`/`lastCharacterOffset` to 0 and only carrying
   `readingProgressPercent` forward. So the restore lookup always saw
   `(0, 0)`, and "resume where you left off" silently never worked, in
   either scroll or paginated mode. Fixed by carrying the position fields
   forward the same way progress already was — fixes it at the source, not
   just at one call site.
5. **`cleanup: remove dead removeFirstLine/enlargeSecondLine settings`**
   Two fully-wired `SettingsManager` properties, reset by
   `resetAllToDefaults()`, but never read by `EPUBParser` and never exposed
   in any Settings pane. Orphaned since "Format for AO3" absorbed their
   behavior. Removed; no functional change (they were dead reads either
   way).
6. **`fix(app): remove duplicate SwiftUI Settings scene`**
   `EPUBReaderApp.swift` built a second, independent `SettingsTabViewController`
   via a SwiftUI `Settings` scene — fixed 480×400, none of
   `SettingsWindowController`'s toolbar tabs/title-sync/frame-autosave/
   animated-resize. Whether this path was ever actually reachable through
   the app's real menu (which `AppDelegate.setupMenus()` fully rebuilds) was
   unverified; if it was, it showed a visibly worse, different Settings
   window. Replaced with an empty placeholder scene (the only `Scene` kind
   that doesn't auto-open a window at launch, needed just to satisfy
   `some Scene` for an otherwise 100% AppKit-driven app).
   `SettingsWindowController.shared` (via `AppDelegate.openSettingsAction`)
   is now the app's only Settings implementation.
7. **`fix(reader): fall back to super.keyDown for unhandled keys in ReaderWindow`**
   `ReaderWindow.keyDown` routed every keystroke to
   `ReaderViewController.handleKeyDown(_:)` and swallowed anything outside
   its five explicit cases instead of falling through to
   `super.keyDown(with:)` — losing AppKit's default unhandled-key behavior
   (e.g. the system beep) for stray keys. `handleKeyDown` now returns
   whether it handled the event; both callers fall back to `super` when it
   didn't.

## Left as documentation only (deliberately not touched)

- **Settings per-tab resize is wired but inert** (`ARCHITECTURE.md` §8):
  the full animated-resize machinery the plan document calls "the core
  structural change" exists and is correctly wired, but every pane reports
  the same hardcoded size, so it never visibly resizes. A doc comment on
  `SettingsPaneMetrics` confirms this is an intentional reversal of an
  earlier, genuinely per-tab-sized version. Since it's a deliberate product
  decision (not a bug), this pass only updates the docs to stop
  contradicting it — no code change.
- **README.md's `screenshots/04.png` alt text** ("Settings - Advanced tab")
  — no "Advanced" tab exists in the app, but the screenshot files aren't in
  this upload, so there's no way to check which tab `04.png` actually shows
  to pick the correct caption. Left unchanged rather than guessed.

## Verification

All 7 patches were applied in sequence with `git am` against a fresh copy
of the uploaded tree and produced an identical result to applying the
combined diff with `git apply`; both were confirmed to apply without
conflicts.
