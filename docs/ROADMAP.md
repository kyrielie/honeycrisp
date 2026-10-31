# Honeycrisp roadmap

This is the only plan document. Superseded plans, surveys and handoffs are deleted, not archived; implementation plans are
handoff files kept outside the repo (see `CLAUDE.md`, Workflows). Design rules and contracts live in `docs/FRAMEWORK.md`; this
file covers decisions, order and gates.

Status: active implementation. Local macOS build and tests are available. Milestones below reflect `main` at 9dd9e37, read
from the code and tests in the 2026-10-30 review (nothing was built or run in that review; test status is the owner's to
confirm with `./test.sh`). 2.2.1 is 3f033bc; the snapshot of the windowed chapter host is branch `chapter-engine` (91c0dfd).
Items marked "verify" are unchecked.

## 1. Baseline

Read from the code at 9dd9e37 on 2026-10-30. "Verified" means read in the named file or symbol; nothing was run.

### 1.1 Built and unbuilt

| Area | State | Evidence |
|---|---|---|
| Content pipeline (R5, R20) | built | `Sources/Content/*`: SwiftSoup, EPUB XHTML parsed as XML, one HTML serialization, concurrent `ChapterPipeline.renderAll`; `EPUBAnchor.currentLayout` is 2 |
| Flow surface, the default (M4a, M5) | built | `FlowSurface`, `FlowDocumentBuilder`, scheme handler, CSP header, `allowsContentJavaScript = false`, client-world scripts; the gate numbers are not recorded (1.2 item 2) |
| Paged mode on the flow surface | built | `FlowDocumentBuilder.buildPagedDocument`, `PaginationJS`, `PaginationEngine` |
| Chapter host (R20 flag mode) | built, frozen | `HONEYCRISP_CHAPTER_HOST=1`: 1,233 lines in `ChapterHost*.swift` and `ServedChapter.swift`, 2,826 lines in 16 `ChapterHost*` test files, 21 references in `ReaderViewController` |
| Formats: EPUB, HTML, Markdown, plain text (M7.1) | built | `BookFormat`, `DocumentImporter`, three importers, four document types in `Honeycrisp/Info.plist`, Open panel, drop target and Finder events use `BookFormat` |
| Formats: PDF, CBZ, MOBI/AZW3 (M7.2 to M7.4) | unbuilt | no PDFKit, image page view or libmobi code in `Sources` |
| Table of contents (M8.1) | built | `TOCModel`, `TOCPopupViewController`, `TOCParser` fallbacks; the sidebar is deleted |
| Back and Forward, bookmarks, search | built | `NavigationHistoryStack`, `BookmarkManager` (with `snippet`), `SearchBarViewController`, Go menu with Cmd-[ and Cmd-] |
| Speech (M9) | built, bugs open | `SpeechCoordinator`, `SpeechTextMap`, `AVFoundationTTSEngine`, highlight overlay, follow-along, toolbar item in the customization palette only; see 1.2 item 1 |
| Book Info, media keys (M9) | built | `BookInfoViewController` (rebindable Cmd-I), `MediaKeyCoordinator` (`MPRemoteCommandCenter`) |
| Typography and themes (M2) | built | `Theme` alignment, hyphenation, spacing, bold weight, import and export, contrast warning |
| Theme files (M2.1, R19) | built | `ThemeStore`, `ThemeFileCodec`, migration flag `readerThemesMigratedToFiles`, flush in `applicationWillTerminate`, Open Themes Folder, rescan on activation |
| Settings window | built | six tabs: General, Reading, Formatting, Appearance, History, Shortcuts (`SettingsTabViewController.tabSpecs`); 15 rebindable actions (`RebindableAction`) |
| Chrome (M8) | unbuilt | no toolbar subtitle, no combined Aa popover, no theme preview toggle; the toolbar has separate font-size and theme-popover items |
| Liquid Glass (M10) | unbuilt | no macOS 26 code; the only `#available` gates are macOS 13.3 and 14 |
| Window state restoration | unbuilt | `ReaderWindowController.setupWindow` sets `isRestorable = false` |
| Parked (R15) | not started | source-style preface, series navigation, Quick Look, Sparkle, notarization; no `.nnwtheme` skin code exists in `main` |

Durable storage, DRM detection limited to real markers, `ReaderCSSSanitizer` and the `ReaderContrast` palette are carried
over from earlier milestones and unchanged.

### 1.2 Known gaps today

1. Speech highlight overlay boxes and search-hit marks are probably invisible. Verified in `ReaderStyles.readerCSS`: `.hc-sp-s`, `.hc-sp-w` and
   `mark.ql-hit` set `background` without `!important`, and the universal rule `* { background-color: transparent !important }`
   outranks them. Nothing sets inline styles on them (`ReaderScripts.swift`). A prior handoff plan measured the same cascade in
   headless Chromium; it was not observed in WebKit or in the app. Paged documents add a second defect (`max-width: 100% !important`
   collapses the zero-width overlay container). No test sees either, because `FlowSpeechHighlightTests` never loads `readerCSS`.
2. The M4a gate for the flow surface was never recorded here. `ReaderBaselineTests` now builds the flow document (it calls
   `FlowDocumentBuilder.buildDocument`), but the tables in M3 are the old merged-document and host numbers, and no flow-surface
   figure or large-book figure is recorded.
3. `WebKitOffsetParityTests.testOffsetParityForEntitiesUnicodeWhitespaceAndSelfClosingAnchor` is still an `XCTExpectFailure`
   (decision B1 says "until M4a replaces the merged document"). M4a is complete and the merged document is deleted, so the
   expectation is stale. The offset contract for the flow surface is covered per section by `ChapterPipelineParityTests`.
4. Dead code (Verified by grep): `FlowSurfaceFlag` and the `HONEYCRISP_FLOW` and `HONEYCRISP_LEGACY` variables are read only by a test,
   because the legacy path was deleted in M5; the six forwarding members at the end of `EPUBParser` (`readerJS`, `readerCSS`,
   `readerVarsCSS`, `monospaceStack`, `imageVisibilityCSS`, `paginatedColumnCSS`) only call `ReaderScripts` and `ReaderStyles`.
5. The three speech settings `speechHighlight`, `speechHighlightWord` and `speechFollow` (all default on) have no control in
   Settings; the Reading tab has voice, rate and auto-scroll only.
6. No tests for `KeyBinding`, `SearchBarViewController` or `ReaderViewController`; `SettingsManager` is tested for themes and
   speech only; `PaginationEngine` navigation is covered only through the surface tests.
7. `ReaderViewController.swift` is 2,910 lines and still holds speech, bookmark, history and flag-mode glue (FRAMEWORK section 2).
8. The pre-migration `readerThemes` blob stays in `UserDefaults` as a rollback copy indefinitely (M2.1 non-blocking default).

Largest real book (owner-supplied; structure Verified by unpacking): 307 chapters, 26.0 MB of XHTML, 23.07M characters, 4.07M
words, no images, no scripts. The owner reports that 2.2.1 opens and reads it, with slow style changes and janky fast scrolling,
and about 65 MB of memory (process not identified; WebContent memory not recorded). Scaling the baseline in M3 linearly predicts
about 870 MB at this size (Unverified; the two figures probably measure different processes). The same book has not been recorded
on the flow surface.

## 2. Decisions

Resolved here as recommendations; reverse any by editing this table and the affected milestone.

| ID | Decision | Reason |
|---|---|---|
| R1 | Keep the book's own styles; override only the properties the user owns (FRAMEWORK C4). The old "no publisher CSS" non-goal is removed. | Stripping loses meaning (class-only italics and bold, verse alignment). Two references that keep publisher CSS (Varq, Rede) reached the same design. Subsumes old D13 and D15. Amended by R20 and R21: the chapter host keeps book styles; the flow surface harvests a whitelist. |
| R2 | Chapters become separate documents inside one `WKWebView`, mounted as a window (FRAMEWORK C5). Construction (iframe per chapter) is confirmed by spike M3, not assumed. Amended by R20: this is the chapter host, retained behind the surface seam and no longer the default. | Keeping book CSS requires isolation per chapter. The same structure gives continuous scroll without loading the whole book. |
| R3 | Resources are served by a scheme handler, from the unpacked folder first. Lazy zip reads with an entry cache come later if needed. | Removes `rewriteResourceURLs`, gives path containment, MIME control, and the place to inject style and `lang`. About 40 to 60 lines in the references. |
| R4 | Build continuous scroll ourselves. Do not adopt foliate-js, Readium, MuPDF or EPUBKit. | None of the references provide continuous scroll across chapters in a DOM reader; foliate-js replaces the position, pagination and search code. Under R20 the default continuous scroll is the browser's own scroll over one document; the windowing code belongs to the chapter host. |
| R5 | SwiftSoup (MIT; pin an exact version after verifying it builds under this project) replaces regex handling of body, style, URLs and active content. Foundation `XMLDocument` stays for OPF and TOC. No Kanna, AEXML, Fuzi. | Regex is the source of the confirmed URL and tag bugs. Gated by the offset parity test (C2). Under R20 it is the one content pipeline for every surface and moves ahead of M4a and M5; EPUB XHTML is parsed as XML and serialized as HTML. Adopted on owner instruction before the spike result was recorded; confirmed by the first green `./test.sh` run. |
| R6 | Two surface kinds: flowing (WebKit) and paged (PDFKit, images). Normalize flowing formats to chapters; do not force PDF or CBZ into chapters. | Matches how each format is actually read; keeps capabilities honest (C9). |
| R7 | Formats, in order: HTML, Markdown and plain text, PDF, CBZ, MOBI/AZW3. HTML, Markdown and plain text are single-file sources that L0 splits into chapters (R22). | Cost and dependency order. HTML, TXT, EPUB, MOBI and AZW3 all appear in the local fanfiction samples. |
| R8 | PDF reflow: no. | Different product; PDFKit search and selection cover the need. Closes old D6. |
| R9 | MOBI/AZW3 via libmobi-swift converting to a temporary EPUB, only if it builds for macOS. Otherwise unsupported with a documented external conversion. No hand-written MOBI reader. Licensing is not a gate. | Only viable reading route found; a 100-line reader lacks images, navigation and KF8. |
| R10 | Content isolation (author JS off, app scripts in their own world) is part of M3, not deferred. Closes old D2 and D14. Applies to every flowing surface under R20. | The scheme handler and chapter host make it cheap now; before them it was expensive. |
| R11 | Continuous scroll position is `(resource, offset)`; progress is derived (C1). Paginated mode paginates per chapter; the displayed page count becomes per chapter or an estimate. This is a visible behavior change, confirmed for flag-mode scroll in M4 (label per chapter, same format as paginated mode). | Global page numbers depend on laying out the whole book. |
| R12 | History retains more entries than it displays (start at 300, measure `UserDefaults` size first); path normalization like bookmarks. Closes old D18 and D19. | The cap of 100 silently drops saved positions. |
| R13 | Navigation history (Back and Forward): yes, as a pure type plus Go-menu items and rebindable shortcuts; toolbar button optional. Closes old D10. | Cheap, testable, high value for footnotes. |
| R14 | Speech highlighting: yes, ON by default, toggleable (`readerSpeechHighlight`). Sentence tint plus an optional word emphasis (`readerSpeechHighlightWord`, default on). Built on the flow surface in scroll and paged modes; the chapter host has no speech and stays frozen. Closes old D11. | The sentence layer does not depend on the word callback, which not every voice delivers (Unverified); offsets come from the C2-parity text map. Default on is an owner decision recorded in the speech handoff plans; the code defaults already match. Recorded here in the 2026-10-30 review: confirm. |
| R15 | Parked: source-style preface (old W14), Series folders and series navigation (old D16), Quick Look (old W8), Sparkle, notarization. | R1 makes the preface mostly unnecessary; the rest need a Developer ID or add sandbox and library-like scope. Revisit on request. |
| R16 | Deployment floor stays macOS 13 for now. Liquid Glass is a later chrome milestone (M10) behind `#available`, written only when it can be tested on macOS 26. Rede is the model. | The reviewer's machine is on macOS 15, so macOS 26 code cannot be tested yet. |
| R17 | ZIP entry-count and size limits: skip. DRM rule and search-hit contrast: already implemented. Closes old D17, D20, D5. | Containment is handled by ZIPFoundation; the rest is done. |
| R18 | Platform chrome work (M8) is independent of the reader pipeline (M3 to M6) and may run in parallel. | No shared files except `ReaderViewController`; coordinate there. |
| R19 | Themes become one JSON file per theme in a folder, replacing the `readerThemes` blob in `UserDefaults`. Folder: `Application Support/Honeycrisp/Themes` inside the app container (the app is sandboxed). File: the `ThemeExport` shape `{version, theme}` with a stable `id`. `readerCurrentThemeID` stays in `UserDefaults`. Amends FRAMEWORK C7. Folder location is confirmed before pass 2 of M2.1. | The folder is a user-visible source of truth (open, copy, back up, hand-edit) and the export format already exists. Costs: a persisted-format change, the end of "`UserDefaults` only" for themes, and an in-memory cache plus debounced writes, because live slider updates would otherwise write files. |
| R20 | One content pipeline (L2: SwiftSoup, EPUB XHTML parsed as XML, one canonical HTML output) feeds two implementations of `FlowingSurface`. `FlowSurface` is the default: the whole book as one document with a `section.hc-chapter[data-resource]` per chapter, served by the scheme handler, content JavaScript off. `ChapterHostSurface` (M3, M4) keeps its iframe-per-chapter windowing, is frozen at bug fixes and stays behind `HONEYCRISP_CHAPTER_HOST=1`. Positions are `(resource, offset)` in both. Engine selection stays a flag; choosing by book size or by a setting is deferred because it brushes the per-book mode non-goal, and needs a decision. The chapter host snapshot is branch `chapter-engine` (91c0dfd). | The M3 adopt decision rested on synthetic fixtures. The owner reports the largest real book (4.07M words) usable in the merged document; isolation matters mainly for books whose meaning depends on their CSS, which the fanfiction samples are not; and the windowing code is the costliest and riskiest part. One pipeline and one position model keep two surfaces cheap. Flag mode has no history, search, speech or bookmarks, so it cannot be the default yet. |
| R21 | The flow surface does not load the book's stylesheets. The pipeline harvests simple rules (`.class`, `#id`, `tag`, `tag.class` selectors) and applies a whitelist as inline style on matching elements: `display:none` (as `hidden`), italic, bold, underline and line-through, centered or right alignment, monospace. Geometry (margins, indent, justification, width) stays with the user layer (C4). Elements are hidden, never deleted, because the offset walk counts hidden text (C2). Cascade order is source order; specificity is not modeled. Amends R1 for that surface. | Generator CSS carries a small amount of meaning (AO3 and FicLab hide elements and define underline, strike and alignment classes) and nothing else in the fanfiction samples needed book CSS. Loading it would need per-chapter isolation. Inline style attributes already survive. |
| R22 | Single-file sources (HTML, TXT, Markdown, legacy MOBI) are split into chapters at L0: `<article>` or generator containers first, then headings, then `mbp:pagebreak` for MOBI, then a size cap at paragraph boundaries; a failed split degrades to one chapter. The Markdown parser choice stays open (M7.1); a small in-house converter for the fanfiction subset is the default proposal. External `http(s)` images are not loaded by default; whether a setting enables them is open and needs a decision. | The samples include single-file HTML, TXT and legacy MOBI whose only chapter signals are those; one Fimfiction HTML hotlinks its cover image. |
| R23 | One table of contents UI: the centered popup (`TOCPopupViewController`, opened by the toolbar button and the View menu item). The sidebar (`TOCSidebarViewController`), its `NSSplitView` host and `TOCSidebarDelegate` are deleted. The popup gains a filter field, keyboard navigation (arrows, Return, Escape) and a key panel. Rows resolve to spine indices once, in a pure `TOCModel` with stable item identity; the current entry is derived from `(spineIndex, fragment)`, not from a file path alone. Resolves the open question in M8 item 4. | Two UIs existed and the sidebar was unreachable (collapsed at load, never toggled). The popup is what users actually see, and it is the Rede-style overlay M8 names as the model. A pure model fixes identity, nested reveal and wrong-current-entry bugs once and is testable without AppKit. TOC jumps for the flow surface stay in M5; the model keys on spine index and fragment so it survives the position model (`Locator`) and non-EPUB sources (M7). |
| R24 | Speech follow-along is on by default (`readerSpeechFollow`). The speech toolbar item (`.speech`) is in the customization palette only, not in the default set, so no toolbar identifier bump. | Optional control without changing existing users' layouts; follow-along is the point of highlighting. Built (`toolbarAllowedItemIdentifiers`, `SettingsManager.resetAllToDefaults`). Recorded here in the 2026-10-30 review from the speech handoff plans: confirm. |

## 3. Milestones

Effort: S under a day, M a few days, L a week or more. Each item is one PR with focused tests. A
milestone is done when its exit criteria hold and the affected docs are updated.

### M0. Baseline and truth (S)

Status: complete except one owner confirmation (the keep/drop decision, keep-set commit and listed cleanup landed at 3f033bc;
the "Doc drift" paragraph of `CLAUDE.md`, the README Linting section and the tab count were corrected in the 2026-10-30 docs
pass; remaining: confirm `./test.sh` passes at 9dd9e37).

- Review the uncommitted diff file by file. Keep: code-font toggle, theme and popover work, new
  theme tests. Drop: `strippingEmbeddedStyles`, its tests, and the `currentLayout` bump to 2 (R1).
  Commit the keep set separately.
- `CLAUDE.md` rewritten to match this plan and `INDEX.md` regenerated from the current tree (done,
  with the helper scripts `scripts/index-anchors.sh` and `scripts/make-diff.sh`). Docs map added to
  the README.
- Delete the stale duplicate `swiftlint.yml` (292 bytes, no dot); `.swiftlint.yml` is the config in use.
- Fix the Settings tab count and the README architecture table.
- Add a one-line note in `ARCHITECTURE.md` that script and URL restrictions are not enforced until M3.

Exit: tree builds, `./test.sh` passes locally, docs list one plan and one design.

### M1. Safety net and contracts (M)

Status: complete (Locator, fraction fallback, and progress derivation are implemented; synthetic
WebKit parity and regression fixtures pass with expected failures for the currently known defects).

- Define `Locator` (C1) as a pure type with the fraction fallback; store `fraction` with new records
  (defaulting decode); make restore read `anchorLayout`. Tests for match, mismatch and missing fields.
- Build the WebKit test harness (C2, C4): load synthetic chapters in a `WKWebView` inside XCTest.
  First test: offset parity on entities, supplementary Unicode, whitespace, `<a id="x"/>`.
- Fixtures for confirmed bugs: nested `Text/Images` layout, `%20` and single-quoted attributes,
  `#fragment` and cross-chapter links, self-closed anchors, class-only italics, centered verse.
- Progress derivation (C1) as a pure function with tests.

Exit: all fixtures exist and the known bugs are reproduced by failing or expected-fail tests.

Harness finding: the first live-DOM parity fixture currently reports a three UTF-16-unit offset
shift from whitespace in the merged-document wrapper. This is an expected failure in M1 and must be
resolved before the M3 host can adopt the parity contract.

### M2. Typography and themes (M, parallel track, independent of M3 to M6)

Status: complete (alignment, language-aware hyphenation, paragraph spacing and optional first-line
indent, bold weight, versioned theme transfer, and non-blocking contrast warnings are implemented;
theme file access uses the selected security-scoped URL; local test script passes).

Order: text alignment and hyphenation per theme (`Theme.textAlign`, `Theme.hyphenate`, vars, reset,
customized check, tests); `EPUBPackage.language` from `dc:language`, sanitized to BCP 47, emitted as
`<html lang>`; `hyphens` plus `-webkit-hyphens` (verify which prefix macOS 13 WebKit honors);
bold text and paragraph spacing; controls in Appearance; theme JSON import and export (version 1,
per-field fallback through the sanitizer, new UUID, never overwrite seeds); contrast warning using
`ReaderContrast.ratio`, warn and do not block. Optional alignment and hyphenation use the low
specificity mechanism in C4. Under R1, the old "font override gaps" (inline font face, SVG text)
are handled by the user layer, not by stripping.

Exit: settings round-trip, existing stored themes still decode, hyphenation does nothing safely when
the language is unknown (help text "Needs book language").

### M2.1. Theme files (M, parallel track, after the M0 keep-set commit)

Status: complete (passes 1 to 3 are in the tree: `ThemeFileCodec`, `ThemeStore`, `SettingsManager` cache and one-time migration, flush in
`applicationWillTerminate`, Open Themes Folder button, Show Themes in Finder menu item, `rescanIfChanged` on activation and when Appearance
opens; covered by `ThemeFileCodecTests`, `ThemeStoreTests`, `SettingsManagerThemeTests`). The exit criteria below were not measured in the review
(Unverified): the owner confirms them by hand. Decision R19. Theme fields, Settings controls and reader CSS did not change.

Design (as built; details of the debounce and migration are in `ThemeStore.swift` and `SettingsManager.swift`):
- One file per theme, `<slug>.honeycrisp-theme.json`, in the `ThemeExport` shape (`{version: 1, theme}`),
  pretty printed with sorted keys. Identity is the `id` inside the file, never the name. Slug: strip `/ : \` and
  control characters and leading dots, trim, cap at about 80 characters, empty becomes "Theme"; collisions are
  compared case-insensitively and numbered. Writes are atomic; write the new file before removing the old one.
- `ThemeFileCodec` (pure) shares sanitizing with `ThemeExport.decode`. Folder loading keeps `id` and honors
  `isDefault` and `seedKey` only when `seedKey` matches a seed; Import still issues a new id. `ThemeStore` is the
  only type that does file I/O and owns an in-memory cache; its directory is injectable for tests.
- `SettingsManager.themes` returns the cache. The setter updates the cache, writes the changed files, then
  notifies, so the existing mutation call sites do not change.
- One-time migration behind the `UserDefaults` flag `readerThemesMigratedToFiles`: run the existing migration chain,
  ensure all three seeds, write every file, set the flag only after all writes succeed. `readerThemes` stays
  untouched as a rollback copy; a corrupt blob goes through `StorageQuarantine` first.
- Seeds: missing seed files are regenerated, existing ones are never overwritten, seeds cannot be deleted.
  Order: seeds first, then custom themes by creation date, then name.
- External edits: rescan on app activation and when Appearance opens, no file watcher; own writes must not look
  like changes (compare decoded values). Unreadable, corrupt or unknown-version files are skipped, logged and never
  rewritten. Duplicate ids: the first wins, the later file is skipped and logged. Hand-edited values pass
  `ReaderCSSSanitizer`. If the folder is not writable, work from memory for the session and show one warning line
  in Appearance.
- UI: "Open Themes Folder" in the Appearance theme actions row and "Show Themes in Finder" in the Theme menu.

Constraints (Verified in code):
- The app is sandboxed (`project.yml`: `ENABLE_APP_SANDBOX: YES`, `ENABLE_USER_SELECTED_FILES: readonly`), so the
  folder lives in the container. A visible location such as `~/Documents` needs an entitlement change and a
  bookmark: a separate decision.
- Numeric Appearance rows fire `onChange` while dragging unless `commitsOnRelease` (`ValueSliderControl`), so
  disk writes must be debounced in the same pass that wires them.
- `AppDelegate` had no will-terminate hook when this was planned; `applicationWillTerminate` now calls
  `ThemeStore.flushPendingWrites`. A resign-active flush was not added (Unverified whether it is needed).

Passes:
1. Codec and store, not wired. Tests: codec round trip keeps `id`, `isDefault`, `seedKey`; a non-seed `seedKey` is
   demoted; the Import path still issues a new id; unknown version rejected; non-finite and out-of-range values
   clamped. Store, in a temp directory: write and reload equality, rename moves the file, delete removes it,
   case-insensitive collision, slug sanitizing, corrupt file skipped and byte-identical, duplicate id, missing seed
   regenerated, edited seed kept, unrelated files ignored, ordering.
2. Wire, migrate and debounce. Cache and injectable directory in `SettingsManager`, diff writes, trailing debounce
   of about 250 ms with a flush on will-terminate and resign-active, one-time migration, seed repair.
   `SettingsManagerThemeTests` and `ReaderStyleTests` inject a temp directory. Migration tests: each legacy
   generation, corrupt blob quarantined first, flag set only after all writes, `readerThemes` untouched, flag set
   with the folder deleted gives fresh seeds. Manager tests: no disk access after the first load, only changed
   files written. Docs in this pass: `CLAUDE.md` persistence invariant, `ARCHITECTURE.md` persistence sentence and
   `SettingsManager` row, `INDEX.md`.
3. Folder access and external changes: the Open Themes Folder button and menu item, rescan on activation, grid
   and Theme menu refresh on external change.

Decisions: blocking before pass 2: folder location (default: container `Application Support/Honeycrisp/Themes`).
Non-blocking, defaults apply: keep `readerThemes` indefinitely and delete nothing in this change; the order rule
above rather than a stored order list; the non-writable and duplicate-id behavior above.

Exit, all measured: editing a theme file in a text editor repaints the reader after the app activates; deleting a
custom theme file removes it from the grid; deleting a seed file regenerates it; an exported theme file dropped
in the folder loads; repeated `themes` reads do no disk access; a slider drag does not write a file per tick;
existing users keep their themes after migration.

### M3. Spike: chapter host, scheme handler, user layer (L, behind a flag)

Status: complete. Outcome (revised by R20): the scheme handler, `ServedChapter`, user layer and client-world isolation are kept and reused; the chapter host (iframe per chapter) is retained behind the surface seam but is no longer the default, and the merged document is replaced by the flow surface (M4a), not by the host. Implemented in M3: (a contained EPUB resource scheme handler and MIME mapping are implemented and
unit covered; the handler also serves `/__app/` app resources and applies a markup transform, and
`ServedChapter.prepare` inserts the stylesheet link and root `lang`, pure and unwired; `ChapterHostCSS` (static
stylesheet plus settings-dependent user block, pure and unwired) and `ChapterHostCascadeTests` prove the
cascade in WebKit; `ChapterHostSurface` shows a three-chapter window in the reader behind `HONEYCRISP_CHAPTER_HOST=1` with author
JavaScript off and a client-world sizing script (read-only; see ARCHITECTURE 4a; assumption A1 is tested by
`ChapterHostShellTests`); `ReaderBaselineTests` also measures the host (`testHostOpen...`, numbers in `build/diagnostics/host-<pages>-pages.txt`, recorded below); the live cosmetic patch is `ChapterHostSurface.applyCosmetics`, covered by `ChapterHostCosmeticPatchTests`; per-chapter offsets and position scroll/read are `honeycrispHost.offsetOfFirstVisibleText` and `scrollTo`, covered by `ChapterHostOffsetParityTests`; frames are re-fitted right after load and when the shell finishes loading, because the first measurement of later frames could be short and was never corrected (`ChapterHostShellTests`); see the outcome above).

Baseline of the current merged-document reader: `ReaderBaselineTests` generates synthetic books of 250 and
2,000 nominal pages (a page is 1,800 characters; 20 pages per chapter) and times the path
`ReaderViewController.renderScrollContent` takes. Recorded 2026-10-20 on macOS 15.8.1 (Xcode version not
recorded; add it), medians of 3 runs, default `WKWebView` without the production message handlers:

| Pages | Chapters | parsePackage | buildScrollHTML | write | load + layout | Open total | HTML | WebContent memory |
|---|---|---|---|---|---|---|---|---|
| 250 | 13 | 2.2 ms | 59 ms | 1.5 ms | 128 ms | about 190 ms | 0.5 MB | 25 MB |
| 2,000 | 100 | 10.5 ms | 469 ms | 5.9 ms | 332 ms | about 820 ms | 3.7 MB | 124 MB |

Open total is build + write + load and layout, plus the one-time parse. Reading: cost is linear in book
size (build 7.9x for 8x pages; WebContent memory 4.9x). The Swift regex pipeline is about 58% of the
2,000-page open, more than WebKit load and layout, so M3 windowing and M6 both act on the dominant cost.
App-process footprint changed by under 4 MB per open, which is measurement noise, not a constraint.
Layout is forced with `scrollHeight` (1,572,882 px at 2,000 pages), so "load + layout" is full-document
layout, not time to first visible text. At 250 pages run 1 was about 24 ms slower than runs 2 and 3 (warm-up).

M3 budgets, from this baseline (edit here to change them): for the same 2,000-page fixture, open at most
200 ms and WebContent memory at most 30 MB, i.e. no worse than today's 250-page book. A result above
that budget but at or below today's 2,000-page figures (820 ms, 125 MB) is not a pass; record it and
weigh it in the adopt or fall-back decision. A result above today's figures rejects the host. The host
is measured with the same generator, run count and median, by extending `ReaderBaselineTests`.

Host measurement (`ReaderBaselineTests.testHostOpen...`), recorded 2026-10-21 on macOS 15.8.1, Xcode 26.3, arm64, medians of
3 runs, window of three chapters, same generator as the baseline, with the frame re-fit in place:

| Pages | Chapters | parsePackage | Host open | Open total | WebContent memory | Budget (2,000 pages) |
|---|---|---|---|---|---|---|
| 250 | 13 | 2.5 ms | 160.5 ms | 162.9 ms | 17.9 MB | n/a |
| 2,000 | 100 | 12.1 ms | 153.6 ms | 165.7 ms | 17.7 MB | at most 200 ms, 30 MB: met |

Reading: host open and memory are flat in book size (the window is three chapters), where the merged document grew 4.3x in
open time and 4.9x in memory. At 2,000 pages the host opens in about 20% of the merged-document time (166 ms against about
820 ms) with about 14% of its WebContent memory (17.7 MB against about 124 MB). A run taken before the frame re-fit fix gave
a host open of 143.6 ms (250 pages, runs 122.6 to 169.2) and 121.4 ms (2,000 pages, runs 116.8 to 136.4). At 250 pages the
run ranges overlap the figures above, so the difference is within noise. At 2,000 pages they do not (137.8 to 162.3 now),
a rise of about 32 ms in the median; the cause is unverified (one run of each, the re-fit or machine variance). The margin to the 200 ms
budget is now about 34 ms. Limits of these numbers: "Host open" ends when the main frame has finished loading and
`scrollHeight` has been read in every mounted chapter, so it excludes the deferred re-fit and first paint; the fixture
chapters are equal in size (20 pages each); one machine. This meets the budgets but is not itself the adopt decision.

Build for one chapter, then a window of three, in the existing book window. Components: scheme
handler (path containment, MIME from manifest, style and `lang` injection), chapter document per
resource served as XML where XHTML, cascade layers (C4), author JS off with app scripts in their own
world (verify API), content isolation checks.

Exit criteria, all measured:
- class-only italics and bold survive; user font, size, color and line height win.
- a synthetic Gutenberg-style chapter (`span.sidenote`, `span.pagenum`, `span.stpagenum` styled by a linked stylesheet) renders as
  the stylesheet directs, not as inline text in the paragraph.
- relative images resolve in nested `Text/Images` layouts with no string rewriting.
- self-closed anchors do not swallow content.
- cosmetic changes patch all mounted chapters without reload.
- position restore by `(resource, offset)` matches the parity test.
- a synthetic 2,000-page book opens in at most 200 ms and WebContent memory stays at or under 30 MB
  (budgets and baseline above), measured with the same method as `ReaderBaselineTests`.
- author scripts do not execute (positive-control test proves the old behavior was observable).

Outcome recorded as a decision: adopt, or fall back to a sanitized merged document with
per-chapter style scoping.

Decision (revised, R20): the host is kept and is not the default. The fall-back, a sanitized merged document, is built as the flow surface (M4a), with the book's styles harvested (R21) instead of scoped per chapter.

### M4. Windowed continuous scroll and per-chapter pagination (L)

Status: paused (R20: the code stays in the tree behind `HONEYCRISP_CHAPTER_HOST=1`, bug fixes only, snapshot branch `chapter-engine` at 91c0dfd; windowing work resumes only if the flow surface fails a measured large-book gate). State at the pause: (scroll windowing, messaging, restore, the scroll baseline and paginated mode in flag mode with chapter
hand-off, exact-offset reflow and the scroll/paged toggle are in code through pass 7; owed: the owner's click-through of the
flag-mode paged reader and the paged memory number). Decisions: flag mode does not read or write saved history in M4 (saved
scroll positions are whole-document offsets with spine index 0, so mapping them to `(resource, offset)` is a persisted-format
decision made in M5); the scroll-mode page label in flag mode is per chapter, same format as paginated mode (R11 confirmed).

Measurement (pass 5): `ReaderBaselineTests.testHostScrollAcrossTwentyBoundariesTwoThousandPageBook` scrolls the 2,000-page fixture
through the real client script across 20 chapter boundaries (3 runs, median of each run's maximum WebContent footprint, budget 30 MB).
Recorded 2026-10-21 (macOS 15.8.1, Xcode 26.3, arm64, one machine): median of each run's maximum WebContent footprint 21.8 MB
(runs 21.6, 21.9 and 21.8 MB; range 21.6 to 21.9), at most 2 chapters mounted at the maximum, 20 of 20 boundaries crossed in
every run, against the 30 MB budget: met. The boundary test (`m4-scroll-boundaries`) crossed 44 boundaries in 800 steps with
at most 4 chapters mounted. The paginated-mode measurement is `ReaderBaselineTests.testHostPagedAcrossTwentyBoundariesTwoThousandPageBook`
(20 consecutive chapters, each reached through the real edge hand-off, same method and 30 MB budget); it writes
`host-paged-2000-pages.txt` and its number is not recorded yet: the owner records it here after a local run.
Pass 7 decisions: paged forward and back returns to the same column (chapter start going forward, chapter end going back); every
reflow or mode change restores the exact text offset (`qlOffsetAtCurrentColumn`, additive in `PaginationJS`), including paged
font-size changes and the paged to scroll toggle.

Mount and evict neighbors near the edges; prepend without visual jump; measure memory. Paginated
mode paginates inside each chapter with a pager hand-off at chapter edges (R11). Update
`scrollRestoreBootstrapJS` and offset restore for the window model.

Exit: scroll across 20 chapter boundaries without jump; paginated forward and back across chapters
restores exact positions; memory within the M3 budget.

### M4a. Flow surface on the content pipeline (L)

Status: complete (Passes 1 to 6 complete: FlowingSurface protocol seam, FlowDocumentBuilder, scheme isolation with client-world scripts, R21 publisher style harvest, section-rooted positions, default flip). Decisions R20, R21, R22.

Design:
- A `FlowingSurface` Swift protocol. `ChapterHostSurface`, `FlowSurface`, and the legacy merged path conform; polymorphic surface calls in `ReaderViewController`. (Complete, Pass 1)
- `FlowDocumentBuilder`: one `section.hc-chapter[data-resource]` per chapter from pipeline output; ids namespaced `hc-r{N}-{id}`; internal links rewritten to namespaced hashes; resource URLs retargeted to custom scheme `honeycrisp-epub://book/...`. (Complete, Pass 2)
- Served by `EPUBResourceSchemeHandler` (`__app/*.html` as `text/html` override), author content JavaScript off (`allowsContentJavaScript = false`), app scripts in `WKContentWorld.defaultClient`, strict CSP, link navigation restricted to in-book resources. (Complete, Pass 3)
- R21 harvest in the pipeline (`ChapterStyles.swift`): whitelist simple `.class`, `#id`, `tag`, `tag.class` rules (display:none as `hidden`, italic, bold, underline, line-through, center/right alignment, monospace); discard geometry and colors; apply Rule N6 semantic HTML5 (`<details open>`, `<nav hidden>`); strip raw `<style>` tags from body. (Complete, Pass 4)
- Positions: the page script walks text from the start of one section and reports `(resource, offset, fraction)`; section offset seek scrolls the target section offset to the reading line. (Complete, Pass 5)
- Default flip: `FlowSurface` is the active default reading surface; `ChapterHostSurface` is reachable via `HONEYCRISP_CHAPTER_HOST=1`. The legacy merged path was deleted in M5, so `HONEYCRISP_FLOW=0` and `HONEYCRISP_LEGACY=1` no longer select anything (`FlowSurfaceFlag` is dead code, 1.2 item 4). (Complete, Pass 6)
- Large books: chapters are parsed concurrently off the main thread. Chunked delivery from the scheme handler and `content-visibility: auto` are options only if a measurement shows the need (both Unverified; see the verify list).

Gate, all measured: parity test (C2) per section on every fixture; hidden text counted equally with and without the harvest; open time and WebContent memory no worse than 2.2.1 on the 2,000-page fixture (about 820 ms, 124 MB) and no worse than the owner's recorded large-book numbers; author scripts do not execute; `<p/>` and `<a id="x"/>` fixtures render correctly; remote images do not load.

Exit: the default path is the flow surface, the chapter host is still reachable through its flag, INDEX and ARCHITECTURE updated.

Open: the gate figures (open time and WebContent memory on the 2,000-page fixture and on the owner's largest book) are not recorded (1.2 item 2). Record them
here, then decide the fate of the chapter host (section 7, item 2).

### M5. Port features to the surface seam, delete the regex path (L)

Status: complete. (Passes 1 to 8 complete: Navigation history stack, Flow TOC and fragment navigation, speech and auto-scroll on FlowSurface, bookmarks on FlowSurface, in-book anchor and cross-chapter links, deleted legacy merged document path and LegacyMergedSurface, EPUBParser modularized across layers).

Pass summary:
- Pass 1 (Decision R13): Navigation history stack (`NavigationLocation`, `NavigationHistoryStack` in `Sources/History/NavigationHistory.swift`), Back (Cmd-[) and Forward (Cmd-]) shortcuts, native Go menu in `AppDelegate`. Tested in `NavigationHistoryTests.swift`.
- Pass 2: TOC and fragment navigation on flow surface (`hc-r{resource}-{id}` namespacing, fallback resolver in `readerJS`). Tested in `FlowTOCNavigationTests.swift`.
- Pass 3: Speech (TTS) and auto-scroll evaluation in client world (`evaluateInSurfaceWorld`), skip hidden/aria-hidden/script/style elements. Tested in `FlowSpeechAndAutoScrollTests.swift`.
- Pass 4: Bookmarks on flow surface (`honeycrispCurrentChapterCharacterOffset` scoped to chapter section, `readPageLocation(spineIndex:)`). Tested in `FlowBookmarkTests.swift`.
- Pass 5: In-book anchor navigation and cross-chapter jumps record navigation history for footnote back-navigation; chapter sync on crossing chapter boundaries. Tested in `FlowLinkNavigationTests.swift`.
- Pass 6: Deleted legacy merged document path (`buildScrollHTML` removed from `EPUBParser.swift`, `LegacyMergedSurface` removed from `FlowingSurface.swift`, `ReaderViewController` defaults directly to `FlowSurface`). Updated all baseline and parity tests to use `FlowDocumentBuilder.buildDocument`.
- Pass 7: Split `EPUBParser.swift` by layer: `EPUBPackage.swift` (L1 Publication), `ChapterSearch.swift` (L2 Content), `ReaderCosmeticSettings.swift` (L3 Reader), `ReaderStyles.swift` (L3 Reader), `ReaderScripts.swift` (L3 Reader). Pure Foundation in L0-L2 with AppKit imports eliminated from parsing.
- Pass 8: Ported paginated mode to `FlowSurface` (`FlowDocumentBuilder.buildPagedDocument`, `PaginationJS` and pager bootstrap in `WKContentWorld.defaultClient`, `__app/paged.html` via scheme handler, deleted legacy `buildPageHTML` and `_ql_reader.html` file writing).

Exit: parity and restore tests green; no reference to the removed functions; INDEX and ARCHITECTURE
updated.

### M6. Content pipeline on SwiftSoup (M)

Status: complete. Moved ahead of M4a and M5 by R20: it is the content pipeline both surfaces use. Throughput recorded on arm64 (8 active cores): single 150 KB chapter render 60.4 ms; 300 chapters renderAll sequential 1745.0 ms, concurrent 1323.9 ms; 300 chapters search 1239.1 ms; 2,000-page buildScrollHTML 408.8 ms.

Move body extraction, active-content removal, AO3 formatting, spacer tagging, preface hiding, URL rewriting and text extraction to
SwiftSoup (`ChapterPipeline`, new files under `Sources/Content/`). The paragraph-indent transform is not ported: `removeParagraphIndents` becomes a no-op until M4a
revisits it. Verify the package builds under the project's settings first. Parse EPUB XHTML with the XML parser and serialize it as HTML, so self-closing non-void tags stay empty elements; decode by BOM, then the XML declaration, then `<meta charset>`, then UTF-8, then windows-1252; hide elements instead of deleting them (R21); measure throughput on a 150 KB chapter and on 300 chapters, parsing chapters concurrently (the call stays synchronous, so the caller's thread is still blocked; M4a moves loading off the main thread). There is no hard time budget: the owner judges speed by feel and the numbers are recorded for reference. Gate: parity test (C2)
passes on every fixture; `layout` version bumped once by M6 (1 to 2), with the fraction fallback tested.

Exit: no regex remains in L2 for HTML structure; chapter bodies contain no `<script>`, `on*` or
`javascript:`.

### M7. Formats (M each, after M5)

Status: M7.1 complete (HTML, Markdown, Plain Text; Verified in `BookFormat`, `DocumentImporter` and `Info.plist`). M7.2 to M7.4 not started (no PDFKit, CBZ or libmobi code).

1. [COMPLETE] HTML, Markdown and plain text (R22): convert to chapters at L0; may start after M6, in parallel with M4a and M5. HTML splits on `<article>` or generator containers, then headings, then a size cap. Plain text normalizes CRLF and encodings, treats a leading `> ` block as the header and `> N. Title` lines as chapter starts (seen in one Fimfiction export), and turns scene-break lines into `<hr>`. The open path hardcodes `epub` (`EPUBDropTargetView`, `ReaderWindowController`, `AppDelegate`) and `Honeycrisp/Info.plist` declares only `org.idpf.epub-container`; both change here. Original item text follows. Plain text is escaping plus paragraph
   detection; Markdown splits chapters on top-level headings. Verify the Markdown parser choice from
   its manifest and docs before adding it (candidates: Foundation Markdown support, or a small
   package); none is assumed. Supported-types registry shared by Open panel, drag-and-drop, Finder
   events and Open Recent, with content validation.
2. PDF: PDFKit view as `PagedSurface`, `Locator.page`, native outline, PDFKit search, capabilities
   exclude themes and speech. Format-discriminated persistence audit lands here (C7); it also covers theme files (R19).
3. CBZ: ZIPFoundation plus an image page view. Natural sort of entries; paged capabilities.
4. MOBI/AZW3: gate on a macOS build of libmobi-swift (its manifest declares iOS only; verify), then
   temporary EPUB conversion with reliable cleanup and history keyed to the original path. Structure seen with a proxy unpacker (KindleUnpack, not libmobi): AZW3 (KF8) unpacks to an ordinary split-part EPUB; legacy MOBI unpacks to one HTML file whose `mbp:pagebreak` markers are the chapter split; the MOBI header encryption field was 0 in all samples and a non-zero value must be reported as DRM.

Exit per format: open, restore, history, bookmarks, error mapping, and tests with generated fixtures.

### M8. Chrome (M, parallel track)

Status: not started. Item 4 is done by M8.1. Of the rest, only the separate font-size and theme-popover toolbar items exist; there is no title and subtitle, no combined Aa popover, no preview toggle (Verified by grep).

Model: Rede's UI, adapted to AppKit and macOS 13. Items in priority order:
1. Native title and subtitle in the toolbar; chapter breadcrumb as the title.
2. One combined "Aa" popover: font size, font, line and paragraph spacing, appearance (system,
   light, dark), two quick swatches, reset that disables at defaults. Full theme editor stays in
   Settings.
3. Settings theme editor: pin the preview above the scroll area; "Preview as Light/Dark" toggle;
   coalesce color-well writes (UI side; the disk-write debounce belongs to M2.1).
4. Contents: decided, one popup (R23, milestone M8.1); small page caption.
5. Dark and light follow the system by default (the setting exists); verify every surface.
All chrome reads from the chrome tokens (C10).

Exit: no hardcoded materials or bar colors outside the chrome definitions.

### M8.1. Table of contents (M, parallel track)

Status: complete. Decision R23. Passes TP1 to TP4 complete: pure `TOCModel` (Foundation-only), modernized `TOCPopupViewController` inside key `TOCPanel` with type-to-filter search and full keyboard navigation (Return/Escape/Arrows), deleted `TOCSidebarViewController` and reader `NSSplitView`, refined `TOCParser` fallbacks (SwiftSoup HTML5 nav parsing, generic and numeric spine title synthesis). Independent of pipeline milestones (M3 to M6). Does not touch offsets (no `currentLayout` bump) or persisted formats.

Findings this milestone fixes (Verified in code unless marked): the sidebar is built then collapsed and never shown; navigation fires
only from a mouse click (`clickedRow`); `TOCEntry` is a struct used as an `NSOutlineView` item; only level 0 is expanded and the
current-row lookup scans visible rows only; "current" is matched by file path, so several entries in one file collide; entries whose
file is not in the spine are silent dead clicks; titles can carry interior newlines; the spine-fallback titles come from filenames
("Part0001"); the regex nav fallback takes every anchor, including landmarks and page-list; `findNav` accepts any file whose name
contains "nav". Unverified until run: the borderless panel's key status and dismissal.

Passes:
1. `TOCModel` (pure Swift, no AppKit): stable class items, spine resolution once, current-entry rule, expansion state, filter. Tests.
2. Popup rebuilt on the model: key panel, filter field, keyboard navigation, current row revealed and selected, `AppDelegate.readerVC()`
   resolves through a child panel, `ReaderViewController` navigates from `TOCEntry` through one method. Sidebar still present, unused by the popup.
3. Delete the sidebar, its split view and delegate; docs (`ARCHITECTURE.md`, `INDEX.md`, `README.md`, `site/index.html`).
4. Parser fallbacks (`TOCParser`): spine-title fallback, nav fallback scope, `findNav` filename test, dead `tocNodes` removed.

Out of scope: TOC jumps in the chapter host (M5), anchor-level current tracking (needs `Locator`, M5), wrapped multi-line rows,
a persistent drawer.

Exit: one TOC UI; type-to-filter and Return work from the keyboard; a nested current chapter is revealed and selected on open; entries
outside the spine cannot be clicked; the selection and filter rules are covered by tests; `./test.sh` passes; docs list one TOC UI.

### M9. Reader features (M each, after M5)

Status: mostly built. Speech (flow surface, both modes, with highlight, follow-along, a `PlaybackState` machine and `SpeechTextMap` abbreviation protection), the Book Info sheet
(`BookInfoViewController`), bookmark snippets (`ReadingBookmark.snippet`) and media keys (`MediaKeyCoordinator`) are in the tree. Open: the speech
highlight is probably invisible (1.2 item 1) and has no Settings controls (item 5); the input and menu audit (the last bullet) was not done. Unverified: that each speech
chunk carries a `Locator`, and which voices deliver word callbacks on macOS 13.

- Speech: one extractor for all chapters with block separators (not shared with search offsets),
  sentence chunking with abbreviation protection, each chunk carrying a `Locator`; word highlight
  from synthesizer range callbacks, off by default (verify the callback and its macOS 13 behavior);
  explicit state machine for start, stop and finish races.
- Book Info sheet from parsed metadata (publisher, language, identifier, date, description);
  store a text snippet with new bookmarks.
- Audit of input and menu requests (full-window drop target, media keys where macOS exposes them,
  auto-scroll hold-to-change, menu completeness, live column changes): mark done, partial, open.

### M10. Platform generation (later)

Status: not started.

Liquid Glass chrome for macOS 26 behind `#available`, written when it can be run and checked on
macOS 26, following Rede. Raise the deployment floor only if a feature requires it. Icon review for
the new platform style.

### Continuous

- Compatibility corpus: record observed outcome per sample class in
  `docs/compatibility-corpus.md`; fix general issues before source-specific ones.
- KEPUB: handle only markers actually observed.
- Settings polish: refresh Appearance after Reset All, swatch accessibility, system spacing.
  Done: numeric Appearance rows are slider plus editable field plus nudge stepper (no wrapping, one
  line-height range, correct labels, structural settings apply on release); controls load stored values when
  the tab is built. Open: preview that shows paragraph spacing and bold weight, paragraph spacing "Book
  Default" (persisted-format change), live relayout of paginated mode after cosmetic changes, Reading-tab
  auto-scroll stepper.
- Collapse empty spacer paragraphs (`SettingsManager.collapseSpacerParagraphs`, off by default) tags
  spacer paragraphs with a class in the current regex pipeline and keeps their text nodes. M6 moves
  `markSpacerParagraphs` to SwiftSoup with the other transforms.
- Docs updated with each milestone; deletion of anything superseded.

## 4. Order

```
M0 -> M1 -> M3 -> M6 -> M4a -> M5 -> M7 (2, 3, 4) -> M9
                    \-> M7.1 (HTML, TXT, Markdown) after M6, parallel with M4a and M5
        M4 (windowed chapter host) paused (R20)
        \-> M2, M2.1 (parallel, after M0; M2.1 needs the keep-set commit)
        \-> M8 (parallel, after M0)   M10 later
        \-> M8.1 (TOC, parallel, after M0; R23)
```

M1 gates M3 (the harness is how the spike is judged). M3's outcome (revised by R20) gates M6 and M4a; M4 is paused. M2, M2.1, M8 and M8.1 touch
settings and chrome, not the pipeline, so they can fill gaps.

## 5. Not planned

Library view, cross-book search, quote sharing, translation, cloud or AI voices, sync, export,
statistics, per-book reading mode, PDF reflow, Quick Look, Sparkle and notarization, series
navigation, source-style preface, hand-written MOBI reader, Readium, foliate-js, MuPDF, EPUBKit,
Kanna, AEXML, Fuzi, SWCompression. Reasons are in section 2 and in the references surveyed; each can
be reopened by editing this file.

## 6. Verify before coding

- Decision B1 (due): M4a replaced the merged document, so the expected failure in `WebKitOffsetParityTests` should be replaced by a per-section assertion or deleted (section 7, item 3).
  Decision B2 is closed: SwiftSoup 2.14.3 is adopted (R5).
- WebKit: author-JS-off semantics with client-world scripts and user scripts on macOS 13;
  `WKURLSchemeHandler` response headers (Content-Security-Policy honored or not); whether
  `ENABLE_OUTGOING_NETWORK_CONNECTIONS` can be dropped once content cannot reach the network.
- Hyphenation prefix honored by macOS 13 WebKit; that low-specificity alignment rules lose to book
  class and inline rules.
- Markdown parser choice and its API; libmobi-swift macOS build.
- ZIPFoundation single-entry read API (needed only for lazy zip serving).
- `AVSpeechSynthesizerDelegate` range callback on macOS 13.
- Which of `NSToolbar` title and subtitle APIs are available at the deployment floor.
- Flow surface (R20, M4a): repeated `WKURLSchemeTask.didReceive(_:)` before `didFinish()` (chunked delivery); whether a `Content-Security-Policy` on app-scheme responses is enforced; client-world registration of the five message handlers `readerJS` uses; `loading="lazy"` on `<img>` with the custom scheme; `content-visibility: auto` on macOS 13 and 14 and its scroll behavior; SwiftSoup XML parse and HTML serialization fidelity and throughput (self-closing tags, namespaces, entities); whether 2.2.1 shows the hidden AO3 `toc-heading` in chapters after the first (`stripPrefaceHeading` only touches spine index 0); which process the owner's 65 MB figure measured; libmobi license and API; the markup inside AO3 HTML `#chapters`.
- M2.1: whether the Theme menu rebuilds on `settingsChangedNotification`; whether any Settings UI reorders
  themes (grep `SettingsWindowController`); that theme Export through the save panel works under
  `ENABLE_USER_SELECTED_FILES: readonly`.
- M8.1 (R23): whether a borderless `NSPanel` subclass with `canBecomeKey` true takes keyboard input and keeps the reader window as `parent`; whether
  clicking the toolbar toggle while the panel is key closes it without reopening (resign-key close versus the button action order);
  `NSWindow.parent` for a child panel inside `AppDelegate.readerVC()`; Escape behavior of `NSSearchField` against the delegate command
  `cancelOperation:`; that clicking a disclosure triangle does not fire the outline view's action; `NSOutlineView` expansion with class items
  across `reloadData`; whether the toolbar toggle state survives a resign-key close.

## 6a. Old identifiers

| Old | Now |
|---|---|
| W0 | M0 |
| W1, W2.1, W2.2, W2.5, W3.1 | done in code (baseline) |
| W2.3, W2.4, W2.6 | M3 (R3, R10), M6 |
| W3.2, W10 | M9 |
| W4 | M5 (R13) |
| W5 | Continuous (corpus) |
| W6, Phases 2, 4, 5 | M7 |
| W7 | M7.4 (R9) |
| W8 | parked (R15) |
| W9 | unchanged: tag-driven ad-hoc releases, Homebrew as the update path |
| W11 | M9 audit, M8 |
| W12 | M9 Book Info; series parked |
| W13 | Continuous, M10 |
| W14 | parked (R1, R15) |
| Theme plan sections 1, 3 | M2 |
| Theme plan section 2 | superseded by R1 |
| D1 to D4 | decided earlier; unchanged |
| D5, D17, D20 | R17 |
| D6 | R8 |
| D9 | R9 |
| D2, D14 | R10 |
| D10, D11 | R13, R14 |
| D12, D13, D15, D16 | R1, R15 |
| D18, D19 | R12 |

## 7. Next work

Ordered by risk to readers first, then by cost. Sizes as in section 3. Each item is a PR or a pass series, with its own tests; none is started.

| # | Item | Why | Size | Gate or decision |
|---|---|---|---|---|
| 1 | Make the speech highlight and search hits visible: give `#hc-speech-hl` boxes and `mark.ql-hit` declarations that outrank the universal `*` rule, fix the paged-mode `max-width` collapse, then add a test that loads the real `readerCSS` and asserts computed colors (1.2 item 1). Follow-ons in the same series: selection extent in scroll mode, follow-along for long and wrapped sentences, "Speak from Here" across chapter sections, a word-callback section gate in `AVFoundationTTSEngine`, and Settings controls for the three speech keys (1.2 item 5). | The feature exists but cannot be seen; search hits share the same defect. Cheapest fix with the largest visible effect. | S for the CSS and test, M for the series | Owner confirms the symptom is in scroll mode before the selection-extent pass; no persisted-format change; `currentLayout` unchanged |
| 2 | Record the M4a gate (2,000-page fixture and the 4.07M-word book on the flow surface), then decide the chapter host: keep frozen, or delete `ChapterHostSurface` and its 16 test files (about 1,233 source and 2,826 test lines, plus 21 references in `ReaderViewController`). | Two surfaces cost review and test time. R20 keeps the host only until a measured large-book gate says whether windowing is needed. | S to measure, M to delete | Blocking owner decision after the numbers; deletion amends R2, R20 and FRAMEWORK C5 |
| 3 | Close decision B1: replace the stale `XCTExpectFailure` in `WebKitOffsetParityTests` with a per-section assertion, or delete the case if `ChapterPipelineParityTests` already covers it. | A permanent expected failure hides a regression in the offset contract (C2). | S | None |
| 4 | Remove dead code: `FlowSurfaceFlag` and its test, the six forwarding members at the end of `EPUBParser`, and the unused speech JS functions `honeycrispCurrentSpeechText` and `honeycrispSpeechOffsetOnScreen` (with the one test that keeps the first alive). Update `INDEX.md` in the same pass. | Misleading flags and shims; the roadmap and architecture documents had described the legacy path as live. | S | Behavior-neutral; call sites move to `ReaderStyles` and `ReaderScripts` |
| 5 | Close the test gaps that need no WebKit: `KeyBinding` (encode, decode, defaults, conflicts), `SettingsManager` setters and reset coverage for each tab, `PaginationEngine` navigation. | The riskiest untested code is persistence and key handling. | M | None |
| 6 | M8 chrome: title and subtitle, then the combined Aa popover, then the theme preview toggle. | The one unbuilt parallel milestone; all items are independent of the pipeline. | M | None; M10 follows only when macOS 26 can be tested |
| 7 | M7.2 PDF (`PagedSurface`, `Locator.page`, PDFKit search, format discriminator in persistence per C7). | The largest format still missing; CBZ and MOBI follow. | L | Owner decision to proceed; persisted-format change |
| 8 | Split `ReaderViewController` by contract, one layer boundary per PR: speech glue first (it already has its own delegate extension and coordinator), then bookmarks and navigation history. | 2,910 lines in one class; FRAMEWORK section 2 marks it as mixed L3, L4 and L5. | M each | Behavior-neutral; only after items 1 and 2, which touch the same regions |
| 9 | Window state restoration (`isRestorable = false` today): restore the book URL and frame through the security-scoped bookmark, never the reading position. | Known gap since the architecture review; not in any milestone. | M | Owner decision; brushes no non-goal |
| 10 | Copy and process: the README and `site/index.html` call Honeycrisp an EPUB reader while HTML, Markdown and plain text also open; consider running `swiftlint` in CI (`CLAUDE.md` says it does not today); keep handoff plans outside the repo tree (`make_upload_zip.sh` packs untracked files, so local handoff files ship in every review zip). | Small, removes recurring drift. | S | Owner decision on CI |

Blocking owner decisions: item 2 (after measuring), item 7, item 9. Non-blocking: item 10.
