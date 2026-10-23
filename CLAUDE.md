# CLAUDE.md

Honeycrisp: native macOS EPUB reader. AppKit + WebKit, SwiftUI only for the `@main` shim.
Read `INDEX.md` first to locate code; it maps files, sections, and common tasks.

## Documents (one of each)
- `docs/FRAMEWORK.md`: target design, layers, contracts, admission rules. Read before any change to
  parsing, rendering, positions, styling, persistence or settings.
- `docs/ROADMAP.md`: the only plan. Decisions R1 to R23, milestones M0 to M10 (M2.1, M4a, M8.1 added), verify list.
- `ARCHITECTURE.md`: what the code does today. `INDEX.md`: code map.
- Superseded documents are deleted, not archived. A milestone is not done until the affected
  document is updated and its `Status:` line in the roadmap is changed. Do not add plan or survey
  documents to the repo; edit these. Implementation plans are handoff files, not repo documents
  (see Workflows).

## Approach
- Read existing files before writing. Don't re-read unless changed.
- Thorough in reasoning, concise in output.
- Skip files over 100KB unless required. `ReaderViewController.swift` (~100KB) and
  `SettingsWindowController.swift` (~92KB) are required for most UI work: read them by line range
  using the section map in `INDEX.md`, not whole. Ranges drift; if one looks wrong run
  `scripts/index-anchors.sh`.
- No sycophantic openers or closing fluff.
- No emojis or em-dashes.
- Do not guess APIs, versions, flags, commit SHAs, or package names. Verify by reading code or docs
  before asserting. Label claims in plans and reports as Verified (with file and symbol) or
  Unverified.
- Stop and ask, do not decide silently, when a change conflicts with `docs/FRAMEWORK.md` or a roadmap
  decision, adds a dependency, changes a persisted format, or changes a contract.

## Build, test, lint
- `project.yml` (XcodeGen) is the source of truth. `Honeycrisp.xcodeproj` is generated output:
  never edit it and never include it in a diff. Some of its files are tracked in git despite
  `.gitignore`; ignore them.
- Any `.swift` file added under `Sources/` or `Tests/HoneycrispTests/` is picked up automatically
  (both `project.yml` and `Package.swift` use directory paths). Run `xcodegen generate` afterwards.
- Generate project: `xcodegen generate` (needs `brew install xcodegen`).
- Test: `./test.sh` (runs xcodegen, then `xcodebuild test`, scheme `Honeycrisp`, unsigned). Env
  overrides: `HONEYCRISP_TEST_DESTINATION`, `HONEYCRISP_DERIVED_DATA`, `HONEYCRISP_RESULT_BUNDLE` (writes an
  `.xcresult` there; used by the local, gitignored `results.sh`).
- Lint: `swiftlint` from the repo root (`brew install swiftlint`; config in `.swiftlint.yml`, line length 160,
  trailing commas required). Fix warnings only in files you touch; no repo-wide reformatting diffs. CI does not
  run it.
- `Package.swift` is a secondary SwiftPM entry point with no test target; CI does not use it.
- Targets: macOS 13.0, Swift 5.9 (the test target declares macOS 14.0 in `project.yml`). Gate newer
  platform APIs with `#available`; do not write macOS 26 (Liquid Glass) code until it can be tested
  (roadmap R16, M10). App dependencies: ZIPFoundation (`from: 0.9.0`, resolved 0.9.20), SwiftSoup (`exactVersion: 2.14.3`, R5 adopted: app and test targets).
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
- Scroll and paginated modes share `ChapterPipeline` in `Sources/Content/` and `readerVarsCSS` in `EPUBParser`.
  Keep them shared so the modes cannot drift. This is the one content pipeline established at roadmap M6 (R20).
- Offsets have one definition (FRAMEWORK C2): the page script's text-node walk, which counts hidden text. Hide elements, never delete them. Any change to what
  `ChapterPipeline`, `ChapterText` or chapter transforms emit changes
  offsets: bump `EPUBAnchor.currentLayout` and run the parity test (roadmap M6/M1).
- Swift to JS bridge: handlers `progressHandler`, `positionHandler`, `pageAction`, `positionUpdate`,
  `pageInfoHandler` are registered in `ReaderViewController.loadView`; JS lives in
  `EPUBParser.readerJS` and `PaginationJS`. A rename must change both sides.
- EPUB content is untrusted. Never interpolate strings into JS directly; use
  `EPUBParser.javaScriptStringLiteral`. Values interpolated into CSS go through `ReaderCSSSanitizer`.
  Script and resource URL restrictions are NOT enforced today (`allowsContentJavaScript` is `true`,
  body scripts survive, URLs are rewritten by regex). Do not assume they exist in the default path. Flag mode (`HONEYCRISP_CHAPTER_HOST=1`, `ChapterHostSurface`) enforces them; roadmap M4a brings them to the default path.
- `HistoryManager.record` must carry saved position and progress forward (regression-tested).
- Settings has one implementation: `SettingsWindowController.shared`, opened from
  `AppDelegate.openSettingsAction`. The SwiftUI `Settings` scene is intentionally empty.
- The Settings per-tab resize machinery is wired but inert by design (all panes are one fixed size).
- Introduce the abstractions in `docs/FRAMEWORK.md` (`Locator`, `Publication`, chapter host,
  capabilities) only at the milestone that needs them, one layer boundary per PR, behavior-neutral.
  Do not refactor `ReaderViewController` broadly outside those steps.
- Style ownership (FRAMEWORK C4): the user layer owns font, size, colors, line height, link colors,
  width, margins, image size and the optional alignment, hyphenation, spacing and weight. It must not
  override italics, bold, small caps, underline, `white-space`, centered text, `display`, direction
  or list styles.

## Non-goals (do not add)
Library view, cross-book search, quote sharing, translation, cloud or AI voices, sync, export,
statistics, per-window or per-book reading mode, PDF reflow. Publisher CSS is no longer a non-goal
(roadmap R1; the flow surface harvests a whitelist instead of loading it, R21). Parked (do not start without a decision): source-style preface, series navigation,
Quick Look, Sparkle and notarization.

## Before adding a feature
Answer in the PR: which principle it serves, which layer owns it, which contract it touches, its test,
its setting and default, and which non-goal it brushes against (FRAMEWORK section 6).

## Workflows

Two modes. The owner may trigger them with a full prompt or a short one ("plan M1", "implement the
plan"). Both assume the whole app is in the uploaded zip and this file has been read.

### Planning
Trigger: "write a detailed plan" for a change or milestone. Role: senior lead developer writing for
another AI engineer who has the zip and this file but no chat history.
- Read `docs/FRAMEWORK.md`, `docs/ROADMAP.md` and `INDEX.md`, then read the code the plan touches by
  range. The plan is written from the code, not from the docs.
- Output one markdown file as a handoff, outside the repo tree and not committed. If the plan changes
  a decision, milestone or contract, the first pass edits `docs/ROADMAP.md` or `docs/FRAMEWORK.md`.
- Sections, in order:
  1. Title, roadmap milestone and decision IDs, base commit and working-tree notes.
  2. Goal and non-goals.
  3. Facts: what the code does now, each cited as `File.swift: Type.method` and tagged Verified or
     Unverified.
  4. Layers and contracts touched (FRAMEWORK C-numbers), and the invariants that apply.
  5. Passes. For each: objective; files and symbols to change; the exact edit (signatures, new types,
     which call sites change); tests to add by name and what each asserts; commands to run; done
     when; what must not be touched; risk and rollback.
  6. Order and dependencies between passes.
  7. Decisions needed, split into blocking and non-blocking.
  8. Verify-before-coding list.
- Style: imperative, no "as discussed", every file and symbol named, no pseudo-steps like "update
  tests as needed".

### Implementation
Trigger: "implement the plan across multiple passes". Work from the plan; do not widen it.
- One pass is one concern and one reviewable diff, about 400 changed lines or fewer excluding tests
  and docs; split anything larger. Each pass leaves the tree consistent and includes its own tests.
- After each pass, build the diff and present it before starting the next; continue to the next pass
  unless a stop condition applies (see Approach).
- Diffs are stacked: pass N is relative to the result of pass N-1. Keep a pristine copy of the
  uploaded tree, build each diff with `bash scripts/make-diff.sh BASE WORK passN-slug.diff` (excludes
  the xcodeproj, `.git-meta`, `.DS_Store`), and check that the whole stack applies in order to the
  pristine copy with `git apply --check` before presenting. Name files `passN-slug.diff`; at the end
  also provide one cumulative diff.
- Same pass: update `INDEX.md` if files or regions moved, `ARCHITECTURE.md` if behavior changed, the
  roadmap `Status:` line if a milestone finished.
- Pass report, short: files changed; tests added; what is untested; commands for the owner
  (`./test.sh`, `swiftlint` on touched files); Verified versus Unverified; anything out of scope
  noticed, listed as follow-ups and not done; what the next pass is.
- Never claim a build or test passed unless it was run in this environment.

## Testing rules
- XCTest with small synthetic fixtures generated in temp directories. Never add real EPUBs;
  `samples/` is local, untracked, and must not be copied from or into the repo.
- In docs and reports record structural facts about local samples (spine counts, class names, tag counts), never titles, authors, text or file contents.
- Add a focused test for any parser, persistence, or position-restore change.
- A test passes or fails. Do not write tests that only record. Measurements and other diagnostics go to a
  file through `TestDiagnostics.write` (`build/diagnostics/`, gitignored, cleared by `test.sh`), never only
  to stdout or an Xcode attachment, so results can be read from the repo.
- No tests exist for `SettingsManager`, `KeyBinding`, `PaginationEngine` (beyond `RestorePosition`),
  `ReaderViewController`, or search UI. Say so when a change touches them.

## Doc drift
`ARCHITECTURE.md` and `README.md` list four Settings tabs in places; code builds five (General,
Reading, Appearance, History, Shortcuts). The README architecture table omits several files.
`ARCHITECTURE.md` section 7 is historical. Trust the code, then fix the doc in the same PR.
