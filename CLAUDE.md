# CLAUDE.md

Honeycrisp: native macOS EPUB reader. AppKit + WebKit, SwiftUI only for the `@main` shim.
Read `INDEX.md` first to locate code; it maps files, sections, and common tasks.

## Approach
- Read existing files before writing. Don't re-read unless changed.
- Thorough in reasoning, concise in output.
- Skip files over 100KB unless required. `ReaderViewController.swift` (~100KB) and
  `SettingsWindowController.swift` (~92KB) are required for most UI work: read them by line range
  using the section map in `INDEX.md`, not whole.
- No sycophantic openers or closing fluff.
- No emojis or em-dashes.
- Do not guess APIs, versions, flags, commit SHAs, or package names. Verify by reading code or docs
  before asserting.

## Build, test, lint
- `project.yml` (XcodeGen) is the source of truth. `Honeycrisp.xcodeproj` is generated output:
  never edit it and never include it in a diff. Some of its files are tracked in git despite
  `.gitignore`; ignore them.
- Any `.swift` file added under `Sources/` or `Tests/HoneycrispTests/` is picked up automatically
  (both `project.yml` and `Package.swift` use directory paths). Run `xcodegen generate` afterwards.
- Generate project: `xcodegen generate` (needs `brew install xcodegen`).
- Test: `./test.sh` (runs xcodegen, then `xcodebuild test`, scheme `Honeycrisp`, unsigned). Env
  overrides: `HONEYCRISP_TEST_DESTINATION`, `HONEYCRISP_DERIVED_DATA`.
- Lint: `xcrun swift-format lint --configuration .swift-format --recursive Sources Tests`
  (4 spaces, 120 columns). Format only touched files; no repo-wide formatting diffs.
- `Package.swift` is a secondary SwiftPM entry point with no test target; CI does not use it.
- Targets: macOS 13.0, Swift 5.9 (the test target declares macOS 14.0 in `project.yml`).
  Only dependency: ZIPFoundation (`from: 0.9.0`, resolved 0.9.20).
- CI (`.github/workflows/`): `tests.yml` on push to main and PRs; `build-dmg.yml` and `release.yml`
  are manual. Releases are ad-hoc signed, not notarized; version comes from the tag.
- `Assets.xcassets/` exists in the repo but is stripped from upload zips by `make_upload_zip.sh`.
- This environment usually has no macOS toolchain. Deliver changes as unified diffs plus the local
  commands to run. Do not claim a build or test passed unless it was actually run.

## Architecture invariants
- One window, view controller, and `WKWebView` per open book. No shared document model, no database.
- Persistence is `UserDefaults` only: settings (`reader*` keys, `appearanceMode`) via
  `SettingsManager`, recents and positions via `HistoryManager` (key `EPUBReaderHistory`), bookmarks via `BookmarkManager`
  (key `HoneycrispReadingBookmarks.v1`), key bindings (`readerKeyBindings`). Change settings through
  `SettingsManager` setters, not raw `UserDefaults` writes, so notifications fire.
- Settings notifications: `.readerCosmeticSettingsChanged` is a live CSS-variable patch with no
  reload; `.readerStructuralSettingsChanged` re-renders the current content. Pick the right one.
- Scroll and paginated modes share `extractedChapterBody` and `readerVarsCSS` in `EPUBParser`.
  Keep them shared so the modes cannot drift.
- Swift to JS bridge: handlers `progressHandler`, `positionHandler`, `pageAction`, `positionUpdate`,
  `pageInfoHandler` are registered in `ReaderViewController.loadView`; JS lives in
  `EPUBParser.readerJS` and `PaginationJS`. A rename must change both sides.
- EPUB content is untrusted. Never interpolate strings into JS directly; use
  `EPUBParser.javaScriptStringLiteral`. Keep resource URL validation and script restrictions.
- `HistoryManager.record` must carry saved position and progress forward (regression-tested).
- Settings has one implementation: `SettingsWindowController.shared`, opened from
  `AppDelegate.openSettingsAction`. The SwiftUI `Settings` scene is intentionally empty.
- The Settings per-tab resize machinery is wired but inert by design (all panes are one fixed size).
- Do not add a generic `Document`/`Publication` abstraction or refactor `ReaderViewController`
  broadly until a second format exists (see `docs/implementation-roadmap.md`).

## Non-goals (do not add)
Library view, cross-book search, publisher CSS, quote sharing, per-window or per-book reading mode.

## Testing rules
- XCTest with small synthetic fixtures generated in temp directories. Never add real EPUBs;
  `samples/` is local, untracked, and must not be copied from or into the repo.
- Add a focused test for any parser, persistence, or position-restore change.
- No tests exist for `SettingsManager`, `KeyBinding`, `PaginationEngine` (beyond `RestorePosition`),
  `ReaderViewController`, or search UI. Say so when a change touches them.

## Doc drift
`ARCHITECTURE.md` and `README.md` list four Settings tabs; code builds five (General, Reading,
Appearance, History, Shortcuts). The README architecture table omits several files. Trust the code.
