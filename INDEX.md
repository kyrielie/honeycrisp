# Honeycrisp code index

Navigation map for development. Base: `main` at 55c9155 plus uncommitted work (listed below). About
10,400 lines of Swift in `Sources/` and 1,500 in `Tests/`. Ranges are at `// MARK:` granularity and
drift: regenerate with `scripts/index-anchors.sh`, then update the tables in the same pass that moves
code. Functions are named, not numbered, so they survive edits. Rules and commands: `CLAUDE.md`.
Target design: `docs/FRAMEWORK.md`. Plan: `docs/ROADMAP.md`. As-built description: `ARCHITECTURE.md`.

## Uncommitted work in this tree

Touches `EPUBParser`, `PaginationEngine`, `ReaderViewController`, `ReaderWindowController`,
`SettingsManager`, `SettingsWindowController`, `ThemePopoverViewController`, plus new
`ReaderStyleTests` and `SettingsManagerThemeTests`. Keep set (roadmap M0): theme and popover work,
the code-font toggle (`useThemeFontForCode`), the new theme tests. Dropped at M0:
`EPUBParser.strippingEmbeddedStyles` and the `currentLayout` bump (the code has
`EPUBAnchor.currentLayout = 1`). Also uncommitted: the "Collapse empty spacer paragraphs" setting
(`collapseSpacerParagraphs`, `EPUBParser.markSpacerParagraphs`, `SpacerParagraphTests`). The diff was
not audited line by line.

## Repo root

| Path | Purpose |
|---|---|
| `project.yml` | XcodeGen source of truth: targets, sandbox, signing settings, scheme |
| `Package.swift` | Secondary SwiftPM entry (`Sources` path, ZIPFoundation, macOS 13); no tests |
| `Honeycrisp/Info.plist` | EPUB document type and `org.idpf.epub-container` UTI declaration |
| `Sources/EPUBReader.entitlements` | Bookmarks app-scope entitlement (excluded from compiled sources) |
| `Assets.xcassets/` | App icon and accent color (in repo, not in upload zips) |
| `test.sh` | xcodegen + `xcodebuild test` wrapper |
| `.swiftlint.yml` | The SwiftLint config in use: line length 160, trailing commas required |
| `swiftlint.yml` | Stale 292-byte duplicate of the above, without the dot; delete it (roadmap M0) |
| `make_upload_zip.sh` | Builds the review zip: tracked files plus `.git-meta/` |
| `scripts/index-anchors.sh` | Prints line counts, MARKs and type declarations for refreshing this index |
| `scripts/make-diff.sh` | Builds a `git apply`-ready diff of a work tree against a base tree |
| `.github/workflows/` | `tests.yml` (push/PR), `build-dmg.yml`, `release.yml` (manual) |
| `docs/` | `ROADMAP.md`, `FRAMEWORK.md`, `compatibility-corpus.md` (see Docs map) |

## Source map

### App (`Sources/App`)
- `EPUBReaderApp.swift` (33): `@main`; adapts `AppDelegate`; empty `Settings` scene by design.
- `AppDelegate.swift` (633): launch, Apple-Event and `open urls` routing (top of file to l.132);
  `// MARK: Menu Setup` (`setupMenus`, l.133-355); live shortcut sync (`syncMenuShortcuts`,
  l.356-395); menu actions (l.396-511, each forwards to `readerVC()?`); helpers incl. `readerVC()`
  (l.512-518); `NSMenuDelegate` dynamic menus (`menuNeedsUpdate`: Open Recent, bookmarks) and
  `validateMenuItem` (l.519-633).

### Reader (`Sources/Reader`)
- `ReaderWindowController.swift` (147): `setupWindow`, `loadEPUB(at:)`, `showOpenPanel`,
  `loadRecent`, `toggleFloat`, `windowWillClose` flushes position. Also `ReaderWindow` (key forwarding).
- `ReaderViewController.swift` (2204): the reading surface. See section map below.
- `PaginationEngine.swift` (269): `ColsPerScreen` (l.38), `RestorePosition` (l.60,
  `.start/.end/.fraction/.characterOffset`), `EPUBAnchor` (l.75; `currentLayout`, `legacyLayout`),
  `PaginationEngine` (l.117, Swift driver of column layout). Bump `currentLayout` when offsets change
  (ARCHITECTURE.md 5a). Nothing reads `anchorLayout` yet (roadmap M1).
- `PaginationJS.swift` (313): JS for paginated mode: column snap, boundaries, char-offset seek.
  Posts `pageAction` and `positionUpdate`.
- `EPUBDropTargetView.swift` (43): drag and drop of `.epub` files.
- `EPUBResourceSchemeHandler.swift` (~100): `honeycrisp-epub://book/...` scheme handler (containment, MIME, optional response headers, `ActiveTaskSet`). Not wired into the reader yet (roadmap M3).

### Parsing (`Sources/Parsing`)
- `EPUBParser.swift` (1356): models, unzip, OPF, DRM, search, HTML and CSS building, `readerJS`.
  See section map below.
- `TOCParser.swift` (335): `TOCEntry`, `TOCNode`, `TOCParser` (`parseTOC`, `tocNodes`,
  `startReadingNode`, `firstSpineIndex(afterCoverIn:)`); EPUB3 nav (`parseNav`), NCX (`parseNCX`),
  spine synthesis (`synthesiseFromSpine`).

### Sidebar (`Sources/Sidebar`)
- `TOCSidebarViewController.swift` (173): outline sidebar; `TOCSidebarDelegate`.
- `TOCPopupViewController.swift` (110): popup TOC outline.
- `SearchBarViewController.swift` (295): in-book search overlay; `SearchBarDelegate`.
- `ThemePopoverViewController.swift` (240): toolbar quick theme switcher (`ThemeRowView`,
  `ThemeSwatchView`).

### History (`Sources/History`)
- `HistoryManager.swift` (268): `HistoryEntry` (Codable, security-scoped bookmark, progress, spine
  index, char offset, `anchorLayout`) and `HistoryManager.shared` (`record`, `updateProgress`,
  `updatePosition`, `savedPosition`, `resolveURL`, `clearAll`; `maxEntries` default 100).
  Notification: `entriesDidChangeNotification`. Load decodes per element; unreadable elements are
  re-emitted after the decoded ones on save and count toward the cap (dropped first); a non-array
  blob is preserved via `StorageQuarantine` before the first overwrite.
- `ReadingBookmark.swift` (172): `ReadingBookmark`, `BookmarkManager` (versioned envelope;
  per-element decode, unreadable elements re-emitted on save, newer version or corrupt blob preserved
  via `StorageQuarantine` before the first overwrite).
- `StorageQuarantine.swift` (55): bounded (3) raw copies under `<key>.quarantine.<unix-seconds>`;
  shared by bookmark and history storage.
- `HistoryViewController.swift` (331): recents popover, `HistoryEntryOpener`, `HistoryRowView`.

### Settings (`Sources/Settings`)
- `SettingsManager.swift` (841): see section map below.
- `SettingsWindowController.swift` (2107): see section map below.
- `KeyBinding.swift` (144): `RebindableAction` (openFile, searchInBook, showTOC, toggleFloat,
  toggleReadingMode) with defaults, `KeyBinding`, storage extension on `SettingsManager`,
  `.keyBindingsChanged`.
- `ShortcutsSettingsViewController.swift` (176): key-capture rows for the Shortcuts tab.
- `ReaderContrast.swift` (76): pure luminance and contrast math, and `hitColors(background:text:)`,
  the search-hit palette (yellow with black on light pages, deep amber with white on dark; active
  hit keeps system selection colors plus an outline). Feeds `ReaderCosmeticSettings.hit*` and the
  `--reader-hit-*` variables in `readerVarsCSS`.
- `ReaderCSSSanitizer.swift` (113): pure validation of values interpolated into `readerVarsCSS` (hex
  colors normalized to `#rrggbb`, font stacks limited to quoted or bare names, numeric clamps
  matching the `SettingsManager` setters). Invalid input returns the fallback, never a partial
  value. Applied in `ReaderCosmeticSettings.current(from:)`.

## Large-file section maps

### `Reader/ReaderViewController.swift`
| Lines | Content |
|---|---|
| 27-167 | Class, state, pagination state (Patch 0007), page-count state, child VCs, layout, toolbar properties |
| 168-405 | View lifecycle: `loadView` (WKWebView config, `allowsContentJavaScript = true`, five message handlers), `viewDidLoad` |
| 406-413 | `beginSecurityAccess` |
| 414-1005 | Mislabeled `MARK: EPUB Loading`; holds far more: `loadEPUB`, `renderCurrentContent`, `renderScrollContent`, `scrollRestoreBootstrapJS`, `loadSpineItem`, `navigate(to:)`, `readPageLocation`; bookmarks (`toggleBookmarkAtCurrentPosition`, `navigate(to bookmark)`); `startReading`, chapter navigation; auto-scroll; speech (`speakCurrentLocation`, rate, voice); `navigateSpine`; scrollbar visibility; `toggleReadingMode` |
| 1006-1022 | Toolbar title (`setToolbarTitle`) |
| 1023-1087 | TOC sidebar host |
| 1088-1111 | Search host |
| 1112-1134 | Context menu |
| 1135-1216 | Display settings: `applyDynamicSettings`, `applyCosmeticCSSUpdate`, `scheduleStructuralReload`, `adjustFontSize` |
| 1217-1367 | Progress reporting and position save and restore: `flushPositionSave`, `reportPaginatedProgress`, `didReceiveScrollPageInfo` |
| 1368-1415 | Navigation and key handling (`handleKeyDown`) |
| 1416-1562 | Scroll-wheel, key monitor and resize (paginated mode only) |
| 1563-1650 | Toolbar updates, helpers (`showLoading`, `showError`), toolbar actions (`showThemePopover`) |
| 1651-1800 | Delegate extensions: TOC sidebar, search bar, split view, window, `AVSpeechSynthesizerDelegate` |
| 1801-1849 | `WKNavigationDelegate` (link policy) |
| 1850-2042 | `NSToolbarDelegate`: `itemForItemIdentifier`, `makeToolbarButton` |
| 2043-2125 | Five private `WKScriptMessageHandler` classes (progress, position, page action, position update, page info) |
| 2126-2204 | `ReaderWebView` (key and context menu), toolbar identifier constants |

### `Parsing/EPUBParser.swift`
| Lines | Content |
|---|---|
| 9-130 | `EPUBPackage`, `EPUBManifestItem`, `EPUBSpineItem`, `EPUBLandmark`, `BookSearchResult`, `ReaderCosmeticSettings` (`current(from:)`), `EPUBParseError` (incl. `.drmProtected`) |
| 131-413 | `EPUBParser`: `javaScriptStringLiteral`, `unpackEPUB`, `isDRMProtected(extractedRoot:)`, `parsePackage`, `searchResults`, `speechText`, `searchableText`, `parseOPF`, `parseLandmarks` |
| 414-775 | HTML building: `buildScrollHTML`, `buildPageHTML`, `paginatedColumnCSS`, `extractedChapterBody`, `stripLeadingIndentWhitespace`, `markSpacerParagraphs`, `stripPrefaceHeading` |
| 722-772 | `MARK: First Chapter Formatting Quirk` (`applyFirstChapterFormatting`), then `extractBody` and `rewriteResourceURLs` (regex URL rewriting) |
| 773-1225 | `readerJS` string: progress, position, page info, chapter navigation, auto-scroll, search |
| 1226-1356 | CSS: `readerVarsCSS` turns `ReaderCosmeticSettings` into CSS variables; `readerCSS` |

### `Settings/SettingsManager.swift`
| Lines | Content |
|---|---|
| 15-185 | `AppearanceMode`, `FontPreset(s)`, `ThemeColorSet`, `Theme`, `ReadingMode`, `NewBookOpensIn` |
| 186-208 | Notification names, `SettingsManager.shared` |
| 209-238 | Font |
| 239-475 | Themes: seed backfill, `themes` getter with legacy migrations, `currentThemeID`, `currentTheme`, `effectiveColorSet`, `updateTheme`, `addTheme`, `deleteTheme` |
| 476-525 | Line height, font size, behaviour flags |
| 526-674 | Pagination; reading-column geometry (incl. `useThemeFontForCode`, `mutateCurrentTheme`, `applyAppearanceOverride`) |
| 675-800 | Reset to defaults: `resetReaderToDefaults`, `resetAllToDefaults` |
| 801-841 | `notifyChange`, `notifyCosmeticChange`, `notifyStructuralChange`, color helpers |

### `Settings/SettingsWindowController.swift`
| Lines | Content |
|---|---|
| 36-160 | `SettingsPaneSizing`, `SettingsPaneMetrics` (fixed pane size), `SettingsWindowController`, `SettingsPanelWindow` |
| 161-289 | `SettingsTabViewController`: five tabs built from `tabSpecs` (General, Reading, Appearance, History, Shortcuts) |
| 290-722 | `GeneralSettingsViewController`, `ReaderSettingsViewController` (the Reading tab) |
| 723-1899 | `AppearanceSettingsViewController`: control factories (l.957), visibility (l.1316), actions (l.1364), theme add, edit, duplicate, delete (l.1532); field and control identity helpers (l.1769); `ThemeBigSwatchButton` (l.1797) |
| 1900-2058 | `HistorySettingsViewController`, table delegate, `HistorySettingsCellView` |
| 2059-2107 | `CustomFontStore`, `CustomFont` |

## Runtime wiring

| Mechanism | Names | Where |
|---|---|---|
| JS to Swift handlers | `progressHandler`, `positionHandler`, `pageInfoHandler` (from `readerJS`); `pageAction`, `positionUpdate` (from `PaginationJS`) | registered in `ReaderViewController.loadView`; handler classes at l.2043-2125 |
| Notifications | `readerCosmeticSettingsChanged`, `readerStructuralSettingsChanged`, `ReaderSettingsChanged` (`settingsChangedNotification`), `keyBindingsChanged`, `ReadingHistoryEntriesDidChange` | `SettingsManager`, `KeyBinding`, `HistoryManager` |
| UserDefaults keys | `reader*` settings keys, `appearanceMode`, `readerThemes`, `readerCurrentThemeID`, `readerKeyBindings`, `customSelectedFontID`, `HoneycrispReadingBookmarks.v1`, `EPUBReaderHistory` | `SettingsManager`, `KeyBinding`, `ReadingBookmark`, `HistoryManager`, `SettingsWindowController` |
| Open-book flow | `AppDelegate`/`ReaderWindowController` -> `ReaderViewController.loadEPUB` -> `EPUBParser.unpackEPUB`, `parsePackage` -> `TOCParser.parseTOC` -> `HistoryManager.record` -> `buildScrollHTML` or `buildPageHTML` -> `loadFileURL` | see `ARCHITECTURE.md` section 4 |

## Where do I change X

| Task | Start here |
|---|---|
| Add or change a menu item | `AppDelegate.setupMenus`; action in the Actions region; `validateMenuItem` |
| Add a rebindable shortcut | `RebindableAction` in `KeyBinding.swift`; `AppDelegate.syncMenuShortcuts`; `ShortcutsSettingsViewController` |
| Add a user setting | Property in `SettingsManager` (call `notifyCosmeticChange` or `notifyStructuralChange`); include in `resetReaderToDefaults` and `resetAllToDefaults`; control in the right pane in `SettingsWindowController`; if it affects rendering, extend `ReaderCosmeticSettings` and `readerVarsCSS` |
| Change reader typography or CSS | `EPUBParser` CSS region (`readerVarsCSS`, `readerCSS`), `paginatedColumnCSS`, `Theme` model |
| Change how a chapter's HTML is cleaned | `extractedChapterBody`, `extractBody`, `rewriteResourceURLs`, `applyFirstChapterFormatting` (any change shifts offsets: see CLAUDE.md invariants) |
| Page turning or column layout | `PaginationEngine`, `PaginationJS`, `ReaderViewController` scroll-wheel, key monitor and resize regions |
| Saved position and progress | `HistoryManager`, `RestorePosition`, `ReaderViewController` position save and restore region, `scrollRestoreBootstrapJS` |
| Table of contents or Start Reading | `TOCParser`, `Sidebar/TOC*`, `ReaderViewController` TOC sidebar host region |
| In-book search | `EPUBParser.searchResults`, `SearchBarViewController`, `ReaderViewController` `SearchBarDelegate` extension |
| Bookmarks | `BookmarkManager`, `ReaderViewController` bookmark functions (inside the EPUB Loading region), `AppDelegate` bookmark menu actions |
| Reading history UI | `HistoryViewController`, `HistoryEntryOpener`, `HistorySettingsViewController` |
| Toolbar buttons | `ReaderViewController` `NSToolbarDelegate` extension (`itemForItemIdentifier`, `makeToolbarButton`), identifier constants at end of file |
| Auto-scroll or speech | `ReaderViewController` auto-scroll and speech functions (inside the EPUB Loading region), `AVSpeechSynthesizerDelegate` extension; menu actions in `AppDelegate` |
| New DRM or parse error | `EPUBParseError`, `EPUBParser.isDRMProtected(extractedRoot:)` (called first by `parsePackage`); error surfaces via `showError` |
| Window behavior, float on top | `ReaderWindowController` (`setupWindow`, `toggleFloat`) |
| Themes | `Theme` and storage in `SettingsManager`, `AppearanceSettingsViewController`, `ThemePopoverViewController` |
| Link policy, script and URL restrictions | `ReaderViewController` `WKNavigationDelegate` extension, `loadView` WKWebView config (restrictions are not enforced yet; roadmap M3) |
| File type registration | `Honeycrisp/Info.plist`, `project.yml` settings |
| Signing, sandbox, version | `project.yml` base settings; workflows for release |

## Tests (`Tests/HoneycrispTests`, XCTest, synthetic fixtures)

| File | Covers |
|---|---|
| `EPUBParserTests.swift` | package and spine parsing, landmarks, search offsets, JS string escaping, DRM rules (LCP file, LCP and ADEPT markers, unknown algorithm; font-obfuscation-only and empty manifests open), missing container, unpack |
| `TOCParserTests.swift` | NCX, EPUB3 nav, nested hierarchy, Start Reading, missing-TOC fallback |
| `HistoryManagerTests.swift` | record, progress and position persistence, clamping, cap, clear, reload, bad-element survival, whole-blob quarantine, unreadable elements and the cap |
| `HistoryEntryTests.swift` | legacy decode defaults (including `anchorLayout`), round-trip of restore position and layout |
| `BookmarkManagerTests.swift` | per-book persistence, rename and remove, corrupt data isolation, bad-element survival, newer version and whole-blob quarantine, quarantine pruning, legacy bookmark decode, anchor layout round trip |
| `RestorePositionTests.swift` | fraction clamping, bootstrap call generation |
| `ReaderCSSSanitizerTests.swift` | hex normalization and injection rejection, preset and custom font stacks, length limits, numeric clamps, non-finite fallback |
| `ReaderContrastTests.swift` | contrast math, hit palette per page luminance, 4.5:1 floor for every seed theme, `--reader-hit-*` variables, no fixed yellow in `readerCSS` |
| `SettingsValueFormatTests.swift` | em, px and line-height labels, typed-number parsing, line-height range shared with the sanitizer, slider snap and clamp math |
| `ReaderStyleTests.swift` (uncommitted) | in-body `<style>` and stylesheet-link stripping (dropped at M0), `--reader-code-font-family` var and `readerCSS` rule, `useThemeFontForCode` default, persistence, reset |
| `LocatorTests.swift` | restore by offset when `layout` matches, by clamped fraction otherwise, Codable round trip, progress from text lengths or byte sizes, nil for paged or unknown resource |
| `EPUBResourceSchemeHandlerTests.swift` | scheme handler path containment (traversal and foreign schemes rejected), MIME mapping, `ActiveTaskSet` bookkeeping, root normalization |
| `ChapterHostSpikeTests.swift` (spike, roadmap M3) | `WKWebView` through the scheme handler: self-closed anchors, nested relative images, class-only italic from book CSS, author script positive control and with content JS off, client-world scripts and message handlers, CSP header, `.html` served as XML, stopping a load mid-flight; outcomes are attachments to record in the roadmap |
| `WebKitOffsetParityTests.swift` | real `WKWebView` harness: offset parity (`XCTExpectFailure`, merged-document wrapper whitespace), known resource and link rewrite bugs (`XCTExpectFailure`), publisher class styles survive |
| `ReaderBaselineTests.swift` (baseline, roadmap M3) | generated synthetic books (250 and 2,000 nominal pages, 20 pages per chapter, nested `Text/` and `Styles/`, relative images): times `parsePackage`, `buildScrollHTML`, file write and `loadFileURL` plus forced layout over 3 runs; best-effort app and WebContent memory; asserts only fixture sanity (chapter count, layout height); numbers are attachments and `BASELINE` stdout lines |
| `SwiftSoupSpikeTests.swift` (spike, roadmap M6/R5) | SwiftSoup 2.14.3 on synthetic XHTML: XML serialization, text-node offsets versus `searchResults`, known `&amp;lt;` double-decode drift (expected failure), active-content removal, spacer detection parity, 1 MB parse time; test-target dependency only |
| `SpacerParagraphTests.swift` (uncommitted) | spacer paragraphs tagged only when the setting is on, real paragraphs and `<pre>` untouched, text nodes unchanged, tag case kept |
| `SettingsManagerThemeTests.swift` (uncommitted) | seed keys, Codable round trip, seed-key migration, reset and customized check by identity, delete protection (isolated `UserDefaults` suite) |

Not covered: `SettingsManager` beyond themes, `KeyBinding`, `PaginationEngine` navigation,
`ReaderViewController`, search UI, all Settings panes, `AppDelegate`. The `WKWebView` harness is
`WebKitOffsetParityTests` only; its parity case is an expected failure until M3 (roadmap decision B1).

## Docs map

| Doc | Use for | Caveat |
|---|---|---|
| `CLAUDE.md` | Rules, workflows (planning and implementation passes), invariants | Keep short; design lives in FRAMEWORK |
| `docs/FRAMEWORK.md` | Target design: layers, contracts (Locator, offsets, style cascade, trust), admission rules | Design, not implemented |
| `docs/ROADMAP.md` | The only plan: decisions R1 to R18, milestones M0 to M10 with status, verify list | Plan; nothing built in review |
| `ARCHITECTURE.md` | What the code does today, data flow, historical decisions | Says four Settings tabs in places; code has five |
| `README.md` | Features, install, build | Architecture table is partial |
| `docs/compatibility-corpus.md` | Synthetic fixture to test mapping, real-file validation table | All real-sample rows pending |

- `SettingsValueFormat.swift`: pure display strings and typed-number parsing for the Appearance sliders (em, px,
  line height).
- `ValueSliderControl.swift`: slider plus editable field plus nudge stepper used by every numeric Appearance row;
  `commitsOnRelease` for settings that re-render the book, throttled live updates for the rest.