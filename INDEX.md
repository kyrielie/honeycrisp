# Honeycrisp code index

Navigation map for development. Line numbers are as of commit `5c3dd27` and drift; re-grep
`// MARK:` lines if a range looks wrong. Rules and commands live in `CLAUDE.md`. Design rationale
lives in `ARCHITECTURE.md`. About 9,300 lines of Swift in `Sources/`.

## Repo root

| Path | Purpose |
|---|---|
| `project.yml` | XcodeGen source of truth: targets, sandbox, signing settings, scheme |
| `Package.swift` | Secondary SwiftPM entry (`Sources` path, ZIPFoundation, macOS 13); no tests |
| `Honeycrisp/Info.plist` | EPUB document type and `org.idpf.epub-container` UTI declaration |
| `Sources/EPUBReader.entitlements` | Bookmarks app-scope entitlement (excluded from compiled sources) |
| `Assets.xcassets/` | App icon and accent color (in repo, not in upload zips) |
| `test.sh` | xcodegen + `xcodebuild test` wrapper |
| `.swiftlint.yml` | SwiftLint rules: line length 160, trailing commas required |
| `make_upload_zip.sh` | Builds the review zip: tracked files plus `.git-meta/` |
| `.github/workflows/` | `tests.yml` (push/PR), `build-dmg.yml`, `release.yml` (manual) |
| `docs/` | Roadmap, corpus notes, settings window status (see Docs map) |

## Source map

### App (`Sources/App`)
- `EPUBReaderApp.swift` (33): `@main`; adapts `AppDelegate`; empty `Settings` scene by design.
- `AppDelegate.swift` (593): launch, Apple-Event and `open urls` routing (l.68-117), all menus
  (`setupMenus` l.127), live shortcut sync (`syncMenuShortcuts` l.340), menu actions (l.372-484),
  `readerVC()` lookup of the key window's reader (l.488), dynamic menus via `NSMenuDelegate`
  (l.500: Open Recent, bookmarks), validation (l.562).

### Reader (`Sources/Reader`)
- `ReaderWindowController.swift` (145): window setup, `loadEPUB(at:)`, `showOpenPanel`,
  `loadRecent`, `toggleFloat`, close flushes position. Also `ReaderWindow` (key forwarding).
- `ReaderViewController.swift` (2047): the reading surface. See section map below.
- `PaginationEngine.swift` (253): `PaginationEngine` (Swift driver of column layout),
  `ColsPerScreen`, `RestorePosition` (`.start/.end/.fraction/.characterOffset`). `EPUBAnchor.currentLayout`: version of the text extraction that saved offsets refer to; bump it when offsets change (ARCHITECTURE.md 5a).
- `PaginationJS.swift` (313): JS for paginated mode: column snap, boundaries, char-offset seek.
  Posts `pageAction` and `positionUpdate`.
- `EPUBDropTargetView.swift` (41): drag and drop of `.epub` files.

### Parsing (`Sources/Parsing`)
- `EPUBParser.swift` (1159): models, unzip, OPF, search, HTML and CSS building, `readerJS`.
  See section map below.
- `ChapterRenderOptions.swift`: value passed to `extractedChapterBody` by the scroll and paginated renderers,
  search and speech, so they all see the same text. Includes optional preface replacement.
- `BookIdentity.swift`, `FrontMatterPlan.swift`, `WorkMeta*.swift`, `FanficPrefaceRenderer.swift`:
  generator recognition, spine roles, metadata extraction and generated fanfiction prefaces.
- `SourceProfiles.swift`: narrow generator-specific HTML and CSS corrections.
- `Sources/Skins/`: `.nnwtheme` model, validation, template renderer, importer, store and four bundled skins.
- `TOCParser.swift` (293): `TOCEntry`, `TOCNode`, `TOCParser`. EPUB3 nav (l.199), NCX (l.152),
  spine-synthesis fallback (l.261), `startReadingNode` (l.71), `firstSpineIndex(afterCoverIn:)`.

### Sidebar (`Sources/Sidebar`)
- `TOCSidebarViewController.swift` (172): outline sidebar; `TOCSidebarDelegate`.
- `TOCPopupViewController.swift` (108): popup TOC outline.
- `SearchBarViewController.swift` (288): in-book search overlay; `SearchBarDelegate`.
- `ThemePopoverViewController.swift`: toolbar skin switcher.

### History (`Sources/History`)
- `HistoryManager.swift` (196): `HistoryEntry` (Codable, security-scoped bookmark, progress,
  spine index, char offset) and `HistoryManager.shared` (`record`, `updateProgress`,
  `updatePosition`, `savedPosition`, `resolveURL`). Notification: `entriesDidChangeNotification`. Load decodes per element; unreadable elements are re-emitted after the decoded ones on save and count toward the cap (dropped first); a non-array blob is preserved via `StorageQuarantine` before the first overwrite.
- `ReadingBookmark.swift`: `ReadingBookmark`, `BookmarkManager` (versioned envelope; per-element decode, unreadable elements re-emitted on save, newer version or corrupt blob preserved via `StorageQuarantine` before the first overwrite).
- `StorageQuarantine.swift`: bounded (3) raw copies under `<key>.quarantine.<unix-seconds>`; shared by bookmark and history storage.
- `HistoryViewController.swift` (326): recents popover, `HistoryEntryOpener`, `HistoryRowView`.

### Settings (`Sources/Settings`)
- `SettingsManager.swift` (769): see section map below.
- `SettingsWindowController.swift` (1998): see section map below.
- `KeyBinding.swift` (143): `RebindableAction` (openFile, searchInBook, showTOC, toggleFloat,
  toggleReadingMode) with defaults, `KeyBinding`, storage extension on `SettingsManager` (l.72),
  `.keyBindingsChanged` (l.142).
- `ShortcutsSettingsViewController.swift` (176): key-capture rows for the Shortcuts tab.
- `ReaderContrast.swift`: pure luminance and contrast math, and `hitColors(background:text:)`, the search-hit palette (yellow with black on light pages, deep amber with white on dark; active hit keeps system selection colors plus an outline). Feeds `ReaderCosmeticSettings.hit*` and the `--reader-hit-*` variables in `readerVarsCSS`.
- `ReaderCSSSanitizer.swift`: pure validation of values interpolated into `readerVarsCSS` (hex colors normalized to `#rrggbb`, font stacks limited to quoted or bare names, numeric clamps matching the `SettingsManager` setters). Invalid input returns the fallback, never a partial value. Applied in `ReaderCosmeticSettings.current(from:)`.

## Large-file section maps

### `Reader/ReaderViewController.swift`
| Lines | Content |
|---|---|
| 25-157 | State, pagination state, page-count state, child VCs, layout, toolbar properties |
| 159-334 | `loadView`: WKWebView config, message handlers registered at l.176-180 |
| 334-397 | `viewDidLoad`, KVO, appear/disappear, `beginSecurityAccess` (l.391) |
| 399-482 | `loadEPUB`: security scope, background unpack/parse, history record, mode choice |
| 483-600 | `renderCurrentContent`, `renderScrollContent`, `scrollRestoreBootstrapJS` (l.526), `loadSpineItem` (l.550) |
| 600-735 | Chapter and bookmark navigation, `startReading`, `goToBeginning`, chapter begin/end |
| 737-830 | Auto-scroll (l.737-770), speech (l.772-825, `AVSpeechSynthesizer`) |
| 831-910 | `navigateSpine`, scrollbar visibility, `toggleReadingMode` (l.868) |
| 910-1010 | Toolbar title, TOC sidebar host, search host |
| 1010-1127 | Context menu, display settings: `applyDynamicSettings`, `applyCosmeticCSSUpdate` (l.1048), `scheduleStructuralReload` (l.1096), `adjustFontSize` |
| 1127-1270 | Progress and position save/restore: `didReceive*` handlers, save timer, `flushPositionSave` (l.1161), `reportPaginatedProgress`, `didReceiveScrollPageInfo` |
| 1270-1460 | Key handling (`handleKeyDown` l.1285), scroll-wheel and key monitors, resize (paginated mode) |
| 1460-1544 | Toolbar updates, `showLoading`/`showError` (l.1474-1480), toolbar actions |
| 1544-1730 | Delegate extensions: TOC sidebar, search bar, split view, window, speech, `WKNavigationDelegate` (l.1683) |
| 1727-1888 | `NSToolbarDelegate`: items (l.1745), `makeToolbarButton` (l.1869) |
| 1888-1970 | Private `WKScriptMessageHandler` classes (5, one per handler name) |
| 1970-2047 | `ReaderWebView` (key and context menu), toolbar identifier constants (l.2035) |

### `Parsing/EPUBParser.swift`
| Lines | Content |
|---|---|
| 8-104 | `EPUBPackage`, `EPUBManifestItem`, `EPUBSpineItem`, `EPUBLandmark`, `BookSearchResult`, `ReaderCosmeticSettings` (`current(from:)` l.77), `EPUBParseError` (incl. `.drmProtected`) |
| 106-328 | `EPUBParser`: `javaScriptStringLiteral` (l.108), `unpackEPUB` (l.113), `parsePackage` (l.129), `searchResults` (l.163), `speechText` (l.191), `parseOPF` (l.222), `parseLandmarks` (l.296) |
| 329-603 | HTML building: `buildScrollHTML` (l.337), `buildPageHTML` (l.385), `paginatedColumnCSS` (l.463), `extractedChapterBody` (l.553), `rewriteResourceURLs` (l.631) |
| 604-654 | First-chapter formatting quirk (`applyFirstChapterFormatting`) |
| 655-1037 | `readerJS` string: progress, position, page info, chapter navigation, auto-scroll, search |
| 1038-1143 | CSS: `readerVarsCSS` (l.1051) turns `ReaderCosmeticSettings` into CSS variables |

### `Settings/SettingsManager.swift`
| Lines | Content |
|---|---|
| 14-170 | `AppearanceMode`, legacy theme decoding models, `ReadingMode`, `NewBookOpensIn` |
| 175-186 | Notification names and `SettingsManager.shared` |
| 190-420 | Font, theme storage, legacy migrations (inline at read time), `updateTheme`/`addTheme`/`deleteTheme` |
| 421-604 | Line height, font size, behaviour flags, pagination, reading-column geometry, `mutateCurrentTheme` (l.558), `applyAppearanceOverride` (l.597) |
| 605-730 | `resetReaderToDefaults` (l.668), `resetAllToDefaults` (l.713) |
| 731-769 | `notifyChange`, `notifyCosmeticChange`, `notifyStructuralChange`, color helpers |

### `Settings/SettingsWindowController.swift`
| Lines | Content |
|---|---|
| 35-160 | `SettingsPaneSizing`, `SettingsPaneMetrics` (fixed pane size), `SettingsWindowController`, `SettingsPanelWindow` |
| 161-281 | `SettingsTabViewController`: five tabs built from `tabSpecs` (General, Reading, Appearance, History, Shortcuts) |
| 292-568 | `GeneralSettingsViewController` |
| 569-692 | `ReaderSettingsViewController` (the "Reading" tab) |
| 726+ | `AppearanceSettingsViewController`: skin selection/import, global reader overrides, typography and preview |
| 1798-1950 | `HistorySettingsViewController` and cell view |
| 1951-1998 | `CustomFontStore`, `CustomFont` |

## Runtime wiring

| Mechanism | Names | Where |
|---|---|---|
| JS to Swift handlers | `progressHandler`, `positionHandler`, `pageInfoHandler` (from `readerJS`); `pageAction`, `positionUpdate` (from `PaginationJS`) | registered `ReaderViewController` l.176-180 |
| Notifications | `readerCosmeticSettingsChanged`, `readerStructuralSettingsChanged`, `ReaderSettingsChanged` (`settingsChangedNotification`), `keyBindingsChanged`, `ReadingHistoryEntriesDidChange` | `SettingsManager`, `KeyBinding`, `HistoryManager` |
| UserDefaults keys | `reader*` settings keys, `appearanceMode`, `readerThemes`, `readerCurrentThemeID`, `readerKeyBindings`, `customSelectedFontID`, `HoneycrispReadingBookmarks.v1`, `EPUBReaderHistory` | `SettingsManager`, `KeyBinding`, `ReadingBookmark`, `HistoryManager`, `SettingsWindowController` |
| Open-book flow | `AppDelegate`/`ReaderWindowController` -> `ReaderViewController.loadEPUB` -> `EPUBParser.unpackEPUB`, `parsePackage` -> `TOCParser.parseTOC` -> `HistoryManager.record` -> `buildScrollHTML` or `buildPageHTML` -> `loadFileURL` | see `ARCHITECTURE.md` section 4 |

## Where do I change X

| Task | Start here |
|---|---|
| Add or change a menu item | `AppDelegate.setupMenus` (l.127); action near l.372-484; validation l.562 |
| Add a rebindable shortcut | `RebindableAction` in `KeyBinding.swift`; `AppDelegate.syncMenuShortcuts`; `ShortcutsSettingsViewController` |
| Add a user setting | Property in `SettingsManager` (call `notifyCosmeticChange` or `notifyStructuralChange`); include in reset functions (l.668, l.713); control in the right pane in `SettingsWindowController`; if it affects rendering, extend `ReaderCosmeticSettings` and `readerVarsCSS` |
| Change reader typography or CSS | `EPUBParser` CSS section (l.1038+), `paginatedColumnCSS`, `Theme` model |
| Change how a chapter's HTML is cleaned | `extractedChapterBody`, `stripActiveContent` (style, script, `on*`, script URLs), `rewriteResourceURLs`, `applyFirstChapterFormatting` |
| Page turning or column layout | `PaginationEngine`, `PaginationJS`, `ReaderViewController` l.1172-1250 and l.1285-1460 |
| Saved position and progress | `HistoryManager`, `RestorePosition`, `ReaderViewController` l.1127-1270, `scrollRestoreBootstrapJS` |
| Table of contents or Start Reading | `TOCParser`, `Sidebar/TOC*`, `ReaderViewController` l.925-986 |
| In-book search | `EPUBParser.searchResults`, `SearchBarViewController`, `ReaderViewController` l.1569 |
| Bookmarks | `BookmarkManager`, `ReaderViewController` l.623-690, `AppDelegate` l.423-455 |
| Reading history UI | `HistoryViewController`, `HistoryEntryOpener`, `HistorySettingsViewController` |
| Toolbar buttons | `ReaderViewController.toolbar(_:itemForItemIdentifier:)` (l.1745), `makeToolbarButton` (l.1869), identifiers (l.2035) |
| Auto-scroll or speech | `ReaderViewController` l.737-830; speech delegate l.1645; menu actions in `AppDelegate` |
| New DRM or parse error | `EPUBParseError` (l.92), `EPUBParser.isDRMProtected(extractedRoot:)` (DRM rules, called first by `parsePackage`; line numbers after l.126 have shifted), `parsePackage`; error surfaces via `showError` |
| Window behavior, float on top | `ReaderWindowController` (`setupWindow`, `toggleFloat`) |
| Reader skins | `.nnwtheme` loader and store in `Sources/Skins`, `AppearanceSettingsViewController`, `ThemePopoverViewController` |
| File type registration | `Honeycrisp/Info.plist`, `project.yml` settings |
| Signing, sandbox, version | `project.yml` base settings; workflows for release |

## Tests (`Tests/HoneycrispTests`, XCTest, synthetic fixtures)

| File | Covers |
|---|---|
| `EPUBParserTests.swift` | package and spine parsing, landmarks, search offsets, JS string escaping, DRM rules (LCP file, LCP and ADEPT markers, unknown algorithm; font-obfuscation-only and empty manifests open), missing container, unpack |
| `ChapterBodyTests.swift` | render options reach search and speech, offsets agree with an independent text collector, single-pass entity decoding, active-content stripping (style, script, `on*`, script URLs) |
| `EPUBFixtures.swift` | helper: on-disk EPUB root with real chapter content (`EPUBFixture.makeRoot`) |
| `TOCParserTests.swift` | NCX, EPUB3 nav, nested hierarchy, Start Reading, missing-TOC fallback |
| `HistoryManagerTests.swift` | record/progress/position persistence, clamping, cap, clear, reload, bad-element survival, whole-blob quarantine, unreadable elements and the cap |
| `HistoryEntryTests.swift` | legacy decode defaults (including `anchorLayout`), round-trip of restore position and layout |
| `BookmarkManagerTests.swift` | per-book persistence, rename/remove, corrupt data isolation, bad-element survival, newer version and whole-blob quarantine, quarantine pruning, legacy bookmark decode, anchor layout round trip |
| `RestorePositionTests.swift` | fraction clamping, bootstrap call generation |
| `ReaderContrastTests.swift` | contrast math, hit palette per page luminance, 4.5:1 floor for every seed theme, `--reader-hit-*` variables, no fixed yellow in `readerCSS` |

Not covered: `SettingsManager`, `KeyBinding`, `PaginationEngine` navigation, `ReaderViewController`,
search UI, all Settings panes, `AppDelegate`.

## Docs map

| Doc | Use for | Caveat |
|---|---|---|
| `ARCHITECTURE.md` | Design, data flow, decisions | Says four Settings tabs; code has five |
| `README.md` | Features, install, build | Architecture table is partial |
| `docs/implementation-roadmap.md` | Phases (PDF, MOBI, format dispatch, Quick Look, AO3 series), architecture rules | Phases 2 to 9 not implemented; Phase 0 gated on sample review |
| `docs/compatibility-corpus.md` | Synthetic fixture to test mapping, real-file validation table | All real-sample rows pending |
| `docs/honeycrisp-settings-window-plan.md` | Settings window status and follow-ups | Follow-ups: reset refresh in Appearance, swatch accessibility |
