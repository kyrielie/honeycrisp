# Plan: themes stored as one JSON file per theme in a folder

Handoff for another AI engineer. Written from the tree in `honeycrisp-upload_1.zip` plus the stepper pass
(`pass1-stepper-fixes.diff`). Nothing here was built or run (no macOS toolchain). Claims are labeled
Verified (read in code) or Unverified.

## 1. Goal

Replace the single `readerThemes` JSON blob in `UserDefaults` with a folder of discrete files, one per
theme, that the user can open, copy, back up and hand-edit. The folder becomes the source of truth.
Nothing about the Theme fields, the settings UI controls or the reader CSS changes.

This changes a persisted format and an architecture invariant (`CLAUDE.md`: "Persistence is
`UserDefaults` only"). The user has chosen this option (option 2). Update the invariant in the same
work, see section 9.

## 2. Current state (Verified)

- Storage: `SettingsManager.themes` (`Sources/Settings/SettingsManager.swift`, getter around line 394)
  decodes `[Theme]` from `defaults.data(forKey: "readerThemes")` on every access. The setter encodes the
  whole array back and calls `notifyChange()`.
- The getter also runs three read-time migrations (missing per-theme typography, missing `isDefault`,
  missing `seedKey`) plus `migrateLegacyThemes(defaults:)` when no `readerThemes` exists. Legacy keys:
  `readerTheme`, `readerCustomBg`, `readerCustomText`, `readerFontFamily`, `readerFont`,
  `readerFontSize`, `readerLineHeight`, `readerMaxWidth`, `readerPaddingH`, `readerPaddingV`.
- Cost: `currentThemeID` reads `themes`, `currentTheme` reads `themes` and `currentThemeID`, and every
  typography property goes through `currentTheme`. `ReaderCosmeticSettings.current(from:)` reads many of
  them, so one cosmetic refresh performs many JSON decodes today. A disk-backed getter would be far
  worse, so the new design needs an in-memory cache.
- All mutation funnels through the `themes` setter: `mutateCurrentTheme`, `updateTheme`, `addTheme`
  (also sets `currentThemeID`), `deleteTheme` (guards: more than one theme, not `isDefault`),
  `resetReaderToDefaults()` (re-inserts missing seeds, restores seed colors and fonts by `seedKey`).
  Keeping the setter signature means these call sites need no change.
- Seeds: `SettingsManager.seedThemes` (Original, Quiet, Paper) with `isDefault: true` and `seedKey`.
  User edits to seeds are persisted in the same list today.
- Selection: `readerCurrentThemeID` in `UserDefaults`. The `currentThemeID` getter already falls back to
  `themes.first` when the stored id is missing.
- `SettingsManager.init(defaults: UserDefaults = .standard)`; tests inject a suite
  (`SettingsManagerThemeTests`, `ReaderStyleTests`).
- Consumers of the list outside the manager: `ThemePopoverViewController` (line ~20, reads on load),
  `SettingsWindowController` (several reads), `AppDelegate` (line ~582, Theme menu).
- Export and import (M2): `ThemeExport` in `SettingsManager.swift` wraps `{version: 1, theme}`.
  `ThemeExport.decode` sanitizes fields but builds a new `Theme` with a fresh UUID and drops `isDefault`
  and `seedKey`. It cannot be used as is for loading stored files (identity would be lost).
- No code opens a themes folder. `Application Support` is used for `Honeycrisp/EPUBReader_<uuid>` work
  dirs (`ReaderViewController` ~line 428) and `CustomFonts` (`SettingsWindowController` ~line 2364).
- Entitlements file contains only `com.apple.security.files.bookmarks.app-scope`; no App Sandbox key
  found in it or in `project.yml`. Unverified: Xcode build settings are generated, so confirm the app
  is not sandboxed before relying on the plain `~/Library/Application Support` path.

## 3. Design

### 3.1 Location and files

- Folder: `~/Library/Application Support/Honeycrisp/Themes/` (reuses the existing `Honeycrisp` parent).
  Resolve with `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
  appropriateFor: nil, create: true)`. Injectable for tests.
- One file per theme: `<slug>.honeycrisp-theme.json`. Same extension the Export panel already suggests,
  so an exported file can be dropped into the folder unchanged.
- Content: the existing `ThemeExport` shape, `{"version": 1, "theme": {...}}`, encoded with
  `.prettyPrinted` and `.sortedKeys` so hand edits and diffs are readable.
- Identity is the `id` inside the file, never the filename. Filenames are cosmetic and may change on
  rename.
- Slug: theme name with `/ : \` and control characters removed, leading dots stripped, trimmed, capped
  at about 80 characters, empty becomes "Theme". Collisions compared case-insensitively (APFS default),
  resolved by appending " 2", " 3". Write the new file first, remove the old one only after success.
- Writes use `Data.write(to:options: .atomic)`.

### 3.2 New types (new files, auto-picked up by `project.yml` and `Package.swift` directory paths)

- `Sources/Settings/ThemeFileCodec.swift`: pure. `encode(_ theme) -> Data`; `decode(_ data,
  preserveIdentity: Bool) -> Theme`. Shares the sanitizing steps with `ThemeExport.decode`; refactor
  that function to call the codec with `preserveIdentity: false`, so Import behavior is unchanged
  (new UUID, `isDefault` false, `seedKey` nil). Folder loading uses `preserveIdentity: true` with these
  rules: keep `id`; honor `isDefault` and `seedKey` only when `seedKey` matches an entry in
  `seedThemes`, otherwise force `isDefault = false`, `seedKey = nil`.
- `Sources/Settings/ThemeStore.swift`: owns the folder and an in-memory `[Theme]` cache.
  - `init(directory: URL, fileManager: FileManager = .default)`
  - `load() -> [Theme]` (scans, decodes, sorts, repairs seeds)
  - `write(_ themes: [Theme], previous: [Theme])` (diff by id: write new and changed files, remove
    files of deleted ids, rename files of renamed themes)
  - `reloadIfChanged() -> Bool` (rescan, report whether the list differs from the cache)
  - `directoryURL` for the UI.
  Keep file I/O out of `SettingsManager` so it stays testable with a temp directory.

### 3.3 SettingsManager wiring

- `init(defaults: UserDefaults = .standard, themesDirectory: URL = ThemeStore.defaultDirectory)`.
- `themes` getter returns the cache (loaded lazily once). The setter updates the cache first, then
  calls `ThemeStore.write(newValue, previous: old)`, then `notifyChange()` as today.
- The three read-time migrations and the legacy-key migration stay, but run only inside the one-time
  import (section 3.4), not on every read.
- `currentThemeID` and `readerCurrentThemeID` stay in `UserDefaults`. It is a preference, not theme
  data.

### 3.4 One-time migration

Condition: UserDefaults flag `readerThemesMigratedToFiles` is not set.
1. If `readerThemes` data exists: take its raw `Data`. If it fails to decode, call
   `StorageQuarantine.preserve(raw, key: "readerThemes", defaults:, reason:)` first, then continue as
   if absent.
2. Run the existing migration chain to produce the list (per-theme typography, `isDefault`,
   `seedKey`, legacy keys), exactly as the getter does now.
3. Ensure all three seeds are present (as `resetReaderToDefaults` does for missing seeds).
4. Write every theme to the folder. Only after all writes succeed, set the flag.
5. Leave `readerThemes` in `UserDefaults` untouched as a rollback copy; never read it again once the
   flag is set. Do not delete it in this change.
A fresh install takes the same path with the seed list.

### 3.5 Seeds

- Missing seed files are regenerated from `seedThemes` on load (matches the existing rule that seeds
  cannot be deleted).
- An existing seed file is never overwritten by code, so user edits to a seed survive. Reset to
  Defaults still restores seed colors and fonts through `resetReaderToDefaults()`, which then writes.
- `deleteTheme` keeps its `isDefault` guard. Deleting a seed file in Finder only causes regeneration.

### 3.6 Ordering

Files have no inherent order, and the grid, popover and menu rely on array order today. Proposed rule,
no new Theme field: seeds first in `seedThemes` order, then custom themes by file creation date
(`URLResourceKey.creationDateKey`), then name. Unverified: whether any UI reorders themes; grep
`SettingsWindowController` before implementing. If reordering exists or is wanted, store the order as a
`[String]` of UUIDs under a new UserDefaults key and apply it on top of this rule (decision, section 8).

### 3.7 External edits

- v1: rescan on `NSApplication.didBecomeActiveNotification` and when the Appearance tab appears. No
  file watcher. In-place edits made by other apps are then picked up as soon as the user returns.
- `reloadIfChanged()` compares decoded themes with the cache by id and value. If the current theme
  changed, post `.readerCosmeticSettingsChanged`; if the list changed, post
  `settingsChangedNotification` so the Appearance grid rebuilds. Our own writes must not trigger a
  reload loop (compare decoded values, not mtimes).
- If the current theme's file disappears, the existing fallback in `currentThemeID` applies.
- Unverified: whether `AppDelegate`'s Theme menu rebuilds on `settingsChangedNotification`. Check
  before relying on it; add a rebuild if not.

### 3.8 Error handling

- A file that cannot be read or decoded, or has an unknown `version`: skip it, log with `os.Logger`
  (same pattern as `StorageQuarantine`), never delete or rewrite it. It reappears if the user fixes
  it.
- Duplicate `id` across files: first by the ordering rule wins; the later file is skipped and logged
  (decision, section 8).
- Hand-edited values go through `ReaderCSSSanitizer` exactly as import does (hex colors, font stack,
  numeric clamps, line-height range from pass 1, paragraph spacing and indent clamps).
- Folder cannot be created or written: keep working from the in-memory list and seeds for the session,
  log, and show one non-blocking warning line in Appearance. No fallback write path to `readerThemes`
  (decision, section 8).

## 4. UI (small)

- Appearance tab, in the existing `themeActions` row next to Import and Export:
  "Open Themes Folder", implemented as `NSWorkspace.shared.open(themesDirectoryURL)` after ensuring the
  folder exists. Selecting the current theme's file with
  `NSWorkspace.shared.activateFileViewerSelecting([fileURL])` is an optional second action.
- Reading > Theme menu (`AppDelegate` ~line 582): a "Show Themes in Finder" item.
- Import keeps its behavior (new UUID) and now also writes into the folder through the normal
  `addTheme` path. Export is unchanged.
- Accessibility labels on any new control, `valueWraps` irrelevant here.

## 5. Passes

One concern per pass; each ends with incremental and combined diffs.

1. **Codec and store, not wired.** `ThemeFileCodec`, `ThemeStore`, refactor `ThemeExport.decode` to
   share sanitizing. Tests with a temp directory. No behavior change in the app.
2. **Wire and migrate.** `SettingsManager` cache, injectable directory, diff writes, one-time
   migration, seed repair, ordering. Update `SettingsManagerThemeTests` and `ReaderStyleTests` setUp
   to inject a temp directory. Add migration tests.
3. **Folder access and external changes.** Open Themes Folder button and menu item, rescan on
   activation, UI refresh on external change, docs.
4. **Write coalescing.** Debounce disk writes (about 250 ms trailing) while keeping cache and
   notifications immediate; flush on `applicationWillTerminate` and when the app resigns active
   (Unverified: confirm `AppDelegate` has a terminate hook). Required before any slider work, since a
   drag produces many writes per second.

## 6. Tests (all pure or temp-directory based)

- Codec: round trip keeps `id`, `isDefault`, `seedKey`; non-seed `seedKey` with `isDefault: true` is
  demoted; import path (`preserveIdentity: false`) still issues a new id; unknown version rejected;
  out-of-range and non-finite values clamped; missing optional fields fall back per field.
- Store: write and reload equality; rename moves the file and keeps one file per id; delete removes the
  file; case-insensitive slug collision; slug sanitizing (slashes, colon, dots, empty, long);
  corrupt file skipped and left byte-identical; duplicate id handling; missing seed regenerated;
  edited seed file preserved; unrelated files in the folder ignored; ordering rule.
- Manager: `themes` getter performs no disk access after first load; setter writes only changed files;
  `resetReaderToDefaults` still restores seeds and rewrites files; existing seed, backfill and
  deletion tests pass unchanged apart from setUp.
- Migration: each legacy generation (no typography, no `isDefault`, no `seedKey`, only legacy keys);
  corrupt `readerThemes` is quarantined first; flag set only after all writes; flag set and folder
  deleted gives fresh seeds, not a re-import; `readerThemes` untouched afterwards.
- External change: edited file detected by `reloadIfChanged()`, own write not detected as a change.

## 7. Risks

- Data loss during migration: mitigated by write-all-then-flag, keeping `readerThemes`, quarantine on a
  corrupt blob.
- Seeds and hand edits: a user can set odd values; the sanitizer bounds them. Contrast is not enforced
  (roadmap: warn, do not block).
- Case-insensitive filesystems and Unicode names: collision rule above; test with names differing only
  by case.
- Sandboxing later would move the folder into the app container; paths come from `FileManager`, so no
  code change, but existing users would not see their old folder (Unverified, future).
- Multiple app instances writing the same folder: not expected (single app, one process); no locking.
- Releases are ad-hoc signed, not notarized; no effect on this change.

## 8. Decisions needed before pass 2

1. Folder location: `Application Support/Honeycrisp/Themes` (default in this plan) versus a visible
   location such as `~/Documents/Honeycrisp Themes`.
2. Ordering: the rule in 3.6, or an explicit order list in `UserDefaults`.
3. Keep `readerThemes` as a rollback copy indefinitely, or delete it after a few releases (default:
   keep, delete nothing in this change).
4. Behavior when the folder is not writable (default: in-memory for the session plus a warning line).
5. Duplicate `id` files (default: skip the later one and log; alternative: assign a new id and rewrite
   the file).

## 9. Documentation to update with the passes

Per `CLAUDE.md`, a milestone is not done until the affected documents change:
- `CLAUDE.md`: Architecture invariants line "Persistence is `UserDefaults` only" gains "except themes,
  which are files in `Application Support/Honeycrisp/Themes`".
- `ARCHITECTURE.md`: the sentence that the only persistent state is `UserDefaults`, and the
  `SettingsManager` row.
- `INDEX.md`: new files and test files; run `scripts/index-anchors.sh` if line ranges drift.
- `docs/ROADMAP.md`: add a line under M2 or Continuous and set its `Status:`.
- `docs/FRAMEWORK.md`: the persistence and theme codec statements (line ~181 mentions
  `decodeIfPresent`, still true).

## 10. Commands for the engineer

```
xcodegen generate
./test.sh
swiftlint
scripts/make-diff.sh BASE_DIR WORK_DIR passN-slug.diff
```
Manual check after pass 3: change a theme in Settings and confirm its file updates in the folder;
edit a color in the file with a text editor, switch back to the app, confirm the reader repaints;
delete a custom theme file and confirm it disappears from the grid; delete a seed file and confirm it
returns; drop an exported file in the folder and confirm it loads.
