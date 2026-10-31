# Honeycrisp code index

Navigation map for development. Base: `main` at 9dd9e37. About
19,500 lines of Swift in `Sources/` and 11,650 in `Tests/` (81 files, 512 test functions). Ranges are at `// MARK:` granularity and
drift: regenerate with `scripts/index-anchors.sh`, then update the tables in the same pass that moves
code. Functions are named, not numbered, so they survive edits. Rules and commands: `CLAUDE.md`.
Target design: `docs/FRAMEWORK.md`. Plan and build status: `docs/ROADMAP.md` (section 1.1 lists built and unbuilt). As-built description: `ARCHITECTURE.md`.

## Repo root

| Path | Purpose |
|---|---|
| `project.yml` | XcodeGen source of truth: targets, sandbox, signing settings, scheme |
| `Package.swift` | Secondary SwiftPM entry (`Sources` path, ZIPFoundation, SwiftSoup, macOS 13); no tests |
| `Honeycrisp/Info.plist` | EPUB document type and `org.idpf.epub-container` UTI declaration |
| `Sources/EPUBReader.entitlements` | Bookmarks app-scope entitlement (excluded from compiled sources) |
| `Assets.xcassets/` | App icon and accent color (in repo, not in upload zips) |
| `screenshots/` | `01.png` to `04.png`; copied into the site by `scripts/build-site.sh`; stripped from upload zips |
| `LICENSE` | License text; stripped from upload zips |
| `test.sh` | xcodegen + `xcodebuild test` wrapper; clears `build/diagnostics/` first and writes `environment.txt` there; `HONEYCRISP_RESULT_BUNDLE` adds `-resultBundlePath` |
| `.swiftlint.yml` | The SwiftLint config in use: line length 160, trailing commas required |
| `make_upload_zip.sh` | Builds the review zip: tracked files plus `.git-meta/` |
| `scripts/index-anchors.sh` | Prints line counts, MARKs and type declarations for refreshing this index |
| `scripts/build-site.sh` | Assembles `_site/` (site plus screenshots and icon); used by `pages.yml` and for local preview |
| `scripts/make-diff.sh` | Builds a `git apply`-ready diff of a work tree against a base tree |
| `.github/workflows/` | `tests.yml` (push/PR), `build-dmg.yml`, `release.yml` (manual), `pages.yml` (push to main touching `site/`, `screenshots/`, the app icon or the build script; or manual) |
| `site/` | Static landing page source for GitHub Pages (`index.html`, `404.html`, `css/site.css`, `js/site.js`). Images are not stored here: `scripts/build-site.sh` copies `screenshots/01-04.png` and the app icon (512 px page icon, favicon, touch icon) into `_site/` |
| `docs/` | `ROADMAP.md`, `FRAMEWORK.md`, `compatibility-corpus.md` (see Docs map) |

## Source map

### App (`Sources/App`)
- `AppDelegate.swift` (752): `@main` entry point with explicit programmatic bootstrap; launch, `applicationWillTerminate` (flushes `ThemeStore`), Apple-Event and `open urls` routing (l.37-162);
  `// MARK: Menu Setup` (`setupMenus`, l.163-411, including the Go menu with Back and Forward and the delegate-populated Theme menu); live shortcut sync (`syncMenuShortcuts`,
  l.412-461); menu actions (l.462-581, each forwards to `readerVC()?`); helpers incl. `readerVC()`
  (l.582-588); `NSMenuDelegate` dynamic menus (`menuNeedsUpdate`: Open Recent, bookmarks, themes plus Show Themes in Finder, l.596-683) and
  `validateMenuItem` (l.684-752).

### Reader (`Sources/Reader`)
- `FlowingSurface.swift`: `protocol FlowingSurface` (L3 surface seam, FRAMEWORK C5) and `extension ChapterHostSurface: FlowingSurface`.
- `FlowDocumentBuilder.swift`: `FlowSurfaceFlag` (unused outside its test; the legacy path it gated is deleted), `FlowDocumentBuilder` (multi-chapter flow document builder, `SectionContext`, element ID namespacing `hc-r{N}-{id}`, internal link rewriting, `wrapSections`).
- `FlowSurface.swift`: `FlowSurface` (flowing reader surface served under `honeycrisp-epub://`, roadmap M4a default surface): `allowsContentJavaScript = false`, client-world user scripts and message handlers, strict CSP headers, in-book navigation link policy.
- `ReaderCosmeticSettings.swift`: `ReaderCosmeticSettings` (pure snapshot of reader styling and contrast hit palette).
- `ReaderStyles.swift`: `ReaderStyles` (`monospaceStack`, `readerVarsCSS`, `readerCSS`, `imageVisibilityCSS`, `paginatedColumnCSS`).
- `ReaderScripts.swift`: `ReaderScripts.readerJS` (client-world scripts for search, position, chapter navigation, and speech).
- `ReaderWindowController.swift`: `setupWindow`, `loadEPUB(at:)`, `showOpenPanel`,
  `loadRecent`, `toggleFloat`, `windowWillClose` flushes position. Also `ReaderWindow` (key forwarding).
- `ReaderViewController.swift`: the reading surface. See section map below.
- `PaginationEngine.swift`: `ColsPerScreen`, `RestorePosition`
  (`.start/.end/.fraction/.characterOffset`), `EPUBAnchor` (`currentLayout = 2`, `legacyLayout = 1`),
  `PaginationEngine` (Swift driver of column layout; `currentOffset`, `invalidate`). Bump `currentLayout` when offsets change
  (ARCHITECTURE.md 5a). `Locator.flowRestoreTarget` compares a saved layout with `currentLayout`.
- `PaginationJS.swift`: JS for paginated mode: column snap, boundaries, char-offset seek.
  Posts `pageAction` and `positionUpdate`. `qlOffsetAtCurrentColumn` (M4 pass 7.2b) returns the offset of the first text on the current page, the inverse of `qlNavigateToOffset`.
- `EPUBDropTargetView.swift`: drag and drop of `.epub` files.
- `EPUBResourceSchemeHandler.swift`: `honeycrisp-epub://book/...` scheme handler (containment, MIME with `text/html` app resource override for flow documents, optional response headers, `ActiveTaskSet`, `/__app/` app resources via `appResources`, markup `transform` hook). Wired for `ChapterHostSurface` and `FlowSurface`.
- `ServedChapter.swift`: pure `ServedChapter.prepare`: inserts the host stylesheet link last in `<head>`, inlines the settings-dependent user block as `<style id="honeycrisp-user">`, adds a missing root `lang`; never edits the body (C2). Used by `ChapterHostSurface` (flag mode only).
- `ChapterHostCSS.swift`: `ChapterHostCSS.stylesheet` (static, served as `__app/reader.css`: reset in `@layer app-reset`, user-owned properties with `!important`) and `userBlock(_:)` (variables from `ReaderStyles.readerVarsCSS` plus the optional alignment, hyphenation and indent rules only while set). Roadmap M3, contract C4. M4 adds `pagedBlock(columnCSS:)`, `pagerBootstrap(cols:restore:)` and `ChapterHostPagedGeometry` (paged presentation).
- `ChapterHostSurface.swift`: `ChapterHostFlag` (`HONEYCRISP_CHAPTER_HOST=1`, not persisted) and `ChapterHostSurface`: `install(into:)` (content JS off, scheme handler, client-world script), `attach(package:cosmetics:)`, `updateServedCosmetics`, `applyCosmetics(_:to:)` (live patch, no reload), `Position`, `Restore`, `onPositionChange`, `firstVisiblePosition`, `scroll(to:in:)`, `load(resource:...)`, `loadPaged(resource:...)` (one chapter as a paged top-level document, geometry stored, scripts re-added per load), `Presentation`, `onPageAction`, `onPagerPosition`, `loadWindow(around:...restoring:)` (a slot per spine item, three mounted), pure `windowIndices` and `estimatedHeight(byteCount:viewportHeight:pixelsPerByte:)`, `chapterURL`, `chapterPath`, `allowsNavigation`. Flag mode is a read-only viewer (ARCHITECTURE 4a).
- `ChapterHostShell.swift`: `ChapterHostShell.html(slots:restore:)` (script-free XHTML shell, a `div.hc-slot` per spine item holding the iframe while mounted, attributes escaped; `html(frames:)` kept as a mounted-only wrapper).
- `ChapterHostScript.swift` and `ChapterHostScriptTail.swift`: `ChapterHostScript.source` (client-world script: frame sizing, `window.honeycrispHost.fitAll`, `applyUserCSS(css)` replacing `<style id="honeycrisp-user">` in every mounted chapter, `offsetOfFirstVisibleText(x)`, `scrollTo(resource, offset)`, `reconcile()`, `mountedResources()` and `pixelsPerByte()`, `restoreTo(resource, offset, fraction)`, `reveal()` and throttled `hostPosition` posts for windowing and measured heights).
- `ChapterHostPaging.swift`: pure `ChapterHostPaging` for paginated mode on the host (M4 pass 7): `handoff(from:forward:count:)` (next chapter at its start, previous at its end, nil at book edges), `restore(for:)` (a scroll-window `Position` as an exact `RestorePosition.characterOffset`), `geometry(viewport:cols:paddingH:paddingV:maxWidth:)`. `changesDocument(from:to:)` (link policy), `pagedTarget(for:fallbackIndex:count:)` (the in-memory restore of a flag-mode paged load), `toPaged(from:activeIndex:count:)` and `toScroll(index:offset:count:)` (the exact-offset restores of the mode toggle). Called by `ReaderViewController.renderCurrentContent`, `navigateSpine`, `loadHostedPagedChapter` and `toggleHostedReadingMode`.
- `ChapterHostHandlers.swift`: `ChapterHostPositionHandler` (client-world `hostPosition`) and `ChapterHostPagerHandler` (client-world `pageAction` and `positionUpdate`), forwarding to `ChapterHostSurface.receive*`.
- `BookInfoViewController.swift`: Book Info sheet from parsed metadata; `cleanDescription(_:)` strips tags and decodes entities (rebindable Cmd-I, `RebindableAction.bookInfo`).
- `MediaKeyCoordinator.swift`: `MediaKeyCoordinator.shared`: `MPRemoteCommandCenter` play, pause and track commands wired to `SpeechCoordinator`; `updateNowPlaying(state:reader:)`.
- `SpeechCoordinator.swift`: speech playback orchestration with sentence chunking, pluggable `TTSEngine`, spine item auto-advance, and progress notifications.
- `SpeechProgress+JS.swift`: string generation for `honeycrispSpeechHighlight` client-world JS call.
- `SpeechStartResolver.swift`: pure resolver mapping caret or selection offset to starting sentence.
- `SpeechToolbarState.swift`: pure toolbar item state machine for `.speech`.
- `TTS/TTSEngine.swift`: backend synthesis protocol and voice descriptors.
- `TTS/AVFoundationTTSEngine.swift`: concrete `AVSpeechSynthesizer` implementation with UTF-16 code unit range handling.

### Content (`Sources/Content`)
- `ChapterDecoder.swift`: pure byte decoding (BOM, XML declaration, meta charset, UTF-8, windows-1252/iso-8859-1 fallback).
- `ChapterMarkup.swift`: syntax mapping, XML/HTML parsing, active content removal, body HTML serialization.
- `ChapterText.swift`: text extraction matching WebKit TreeWalker, hidden ranges detection.
- `SpeechTextMap.swift`: bidirectional mapping between spoken sentences and chapter UTF-16 offsets with block-break preservation and skip ranges.
- `ChapterTransforms.swift`: AO3 formatting, spacer paragraph marking, and preface heading hiding in the DOM.
- `ChapterURLs.swift`: DOM URL rewriting (resolving against chapter directory, containment in root, scheme URLs and fragments preserved).
- `ChapterStyles.swift`: publisher stylesheet harvesting (Rule N3) for simple selectors, inlining whitelisted typography (italic, bold, underline/line-through, center/right alignment, monospace) and display:none as `hidden`, discarding geometry/colors, applying Rule N6 HTML5 semantics (`<details open>`, `<nav hidden>`), and stripping raw `<style>` elements (Decision R21).
- `ChapterPipeline.swift`: pipeline facade for decoding, parsing, transforms, style harvesting, URL rewriting into served body HTML and text, and concurrent batch processing (`renderAll`).
- `ChapterSearch.swift`: text search (`searchResults`) and speech extraction (`speechText`, `speechMap`, `speechChunkRanges`) over package chapters using `ChapterPipeline`.

### Parsing (`Sources/Parsing`)
- `BookFormat.swift`: format detection enum (`BookFormat`), UTI mappings, file extension matching, and support predicates.
- `DocumentImporter.swift`: unified importation entrypoint (`DocumentImporter`, `DocumentImporterError`) dispatching to EPUB, plain text, HTML, and Markdown importers.
- `EPUBPackage.swift`: publication data types (`EPUBPackage`, `EPUBManifestItem`, `EPUBSpineItem`, `EPUBLandmark`, `BookSearchResult`, `EPUBParseError`).
- `EPUBParser.swift` (337): pure Foundation and ZIPFoundation unzip, OPF/spine parsing, DRM detection, landmarks extraction, and `javaScriptStringLiteral` (AppKit-free, WebKit-free). Its last members (`readerJS`, `readerCSS`, `readerVarsCSS`, `monospaceStack`, `imageVisibilityCSS`, `paginatedColumnCSS`) only forward to `ReaderScripts` and `ReaderStyles`; call sites should move there (roadmap section 7, item 4).
- `HTMLDocumentImporter.swift`: ingests standalone HTML, strips active scripts/objects, splits into logical chapters via articles/headings, synthesizes EPUBPackage with NCX TOC.
- `MarkdownImporter.swift`: parses CommonMark/GFM blocks, extracts YAML frontmatter and heading metadata, splits into chapters by headings, synthesizes EPUBPackage with NCX TOC.
- `PlainTextImporter.swift`: decodes plain text with encoding fallbacks, extracts metadata/headings, detects scene breaks, synthesizes multi-chapter EPUBPackage with NCX TOC.
- `TOCParser.swift` (374): `TOCEntry`, `TOCNode`, `TOCParser` (`parseTOC`,
  `startReadingNode`, `firstSpineIndex(afterCoverIn:)`, `fallbackTitle`); EPUB3 nav (`parseNav` with SwiftSoup HTML5 fallback), NCX (`parseNCX`),
  spine synthesis (`synthesiseFromSpine`).

### Sidebar (`Sources/Sidebar`)
- `TOCModel.swift` (285): pure model for TOC hierarchy, resolution, expansion, and filtering (`TOCLocation`, `TOCItem`, `TOCModel`).
- `TOCPopupViewController.swift` (372): popup TOC outline with type-to-filter search (`TOCPanel`, `TOCOutlineView`, `TOCPopupViewController`).
- `SearchBarViewController.swift` (295): in-book search overlay; `SearchBarDelegate`.
- `ThemePopoverViewController.swift` (245): toolbar quick theme switcher (`ThemeRowView`,
  `ThemeSwatchView`).

### History (`Sources/History`)
- `NavigationHistory.swift`: `NavigationLocation`, `NavigationHistoryStack` (Back/Forward navigation stack for Decision R13, bounded history depth, push/back/forward operations).
- `HistoryManager.swift`: `HistoryEntry` (Codable, security-scoped bookmark, progress, spine
  index, char offset, `anchorLayout`) and `HistoryManager.shared` (`record`, `updateProgress`,
  `updatePosition`, `savedPosition`, `resolveURL`, `clearAll`; `maxEntries` default 100).
  Notification: `entriesDidChangeNotification`. Load decodes per element; unreadable elements are
  re-emitted after the decoded ones on save and count toward the cap (dropped first); a non-array
  blob is preserved via `StorageQuarantine` before the first overwrite.
- `Locator.swift` (61): `Locator` (`.flow(resource, offset, layout, fraction)`, `.page(index)`); `flowRestoreTarget` gives an exact offset when `layout == EPUBAnchor.currentLayout`, else a clamped fraction; `ResourceProgressMeasure`; `ReadingProgress.fraction(for:resources:)`. Read through `HistoryManager.savedLocator(for:)` (FRAMEWORK C1).
- `ReadingBookmark.swift` (178): `ReadingBookmark`, `BookmarkManager` (versioned envelope;
  per-element decode, unreadable elements re-emitted on save, newer version or corrupt blob preserved
  via `StorageQuarantine` before the first overwrite).
- `StorageQuarantine.swift` (55): bounded (3) raw copies under `<key>.quarantine.<unix-seconds>`;
  shared by bookmark and history storage.
- `HistoryViewController.swift` (331): recents popover, `HistoryEntryOpener`, `HistoryRowView`.

### Settings (`Sources/Settings`)
- `SettingsManager.swift` (1073): see section map below.
- `SettingsWindowController.swift` (2382): see section map below.
- `ThemeFileCodec.swift` (102): pure `ThemeFileCodec`: `encode(theme:)`, `decode(data:validSeedKeys:)` (keeps `id`, honors `seedKey` only when recognized, rejects unknown versions), `slug(for:)`, `filename(for:collisionIndex:)`; shares sanitizing with `ThemeExport.decode`.
- `ThemeStore.swift` (342): `ThemeStore` (R19, M2.1): the only theme file I/O. Directory `Application Support/Honeycrisp/Themes` (injectable), in-memory `themes` cache, `setThemes(_:debounce:)` with a 250 ms trailing write, `flushPendingWrites()`, `rescanIfChanged()`, seed regeneration, corrupt files skipped and never rewritten.
- `FanfictionSettingsViewController.swift` (125): the Formatting tab: Format for AO3, remove indents, collapse spacer paragraphs.
- `KeyBinding.swift` (189): `RebindableAction` (15 actions: file, search, TOC, float, reading mode, Book Info, beginning and end, chapter navigation, speech, auto-scroll, font size, bookmark) with defaults, `KeyBinding`, storage extension on `SettingsManager`,
  `.keyBindingsChanged`.
- `ShortcutsSettingsViewController.swift` (238): key-capture rows for the Shortcuts tab.
- `SettingsValueFormat.swift` (35): pure display strings and typed-number parsing for the Appearance sliders (em, px, line height).
- `ValueSliderControl.swift` (180): slider plus editable field plus nudge stepper used by every numeric Appearance row; `commitsOnRelease` for settings that re-render the book, throttled live updates for the rest.
- `ReaderContrast.swift` (128): pure luminance and contrast math, and `hitColors(background:text:)`,
  the search-hit palette (yellow with black on light pages, deep amber with white on dark; active
  hit keeps system selection colors plus an outline). Feeds `ReaderCosmeticSettings.hit*` and the
  `--reader-hit-*` variables in `readerVarsCSS`.
- `ReaderCSSSanitizer.swift` (137): pure validation of values interpolated into `readerVarsCSS` (hex
  colors normalized to `#rrggbb`, font stacks limited to quoted or bare names, numeric clamps
  matching the `SettingsManager` setters). Invalid input returns the fallback, never a partial
  value. Applied in `ReaderCosmeticSettings.current(from:)`.
- `ChapterTransformSettings.swift` (11): extension `ChapterTransformOptions.current(from:)` reading
  `formatFirstChapter` and `collapseSpacerParagraphs` to bridge user preferences into L2 pipeline options.

## Large-file section maps

### `Reader/ReaderViewController.swift`
| Lines | Content |
|---|---|
| 26-173 | Class, state, pagination state, page-count state, child VCs, layout, toolbar properties |
| 174-443 | View lifecycle: `loadView` (surface selection, `ChapterHostFlag` branch at l.190, client-world message handlers), `viewDidLoad` |
| 444-451 | `beginSecurityAccess` |
| 452-842 | `MARK: Document Loading`: `loadDocument`, `loadEPUB`, `finishLoading`, `initialSpineIndex`, `applyRestoreTarget`, `renderCurrentContent` (`renderFlowContent`, `renderHostedChapter`), `loadSpineItem`, `loadFlowPagedChapter`, `loadHostedPagedChapter`, `reloadPagedAtCurrentOffset`, `updateCurrentChapter` |
| 843-1390 | Mislabeled `MARK: Navigation History (Decision R13)`; holds far more: `navigate(to:)` (l.818), `goBack`, `goForward`, `evaluateInSurfaceWorld` (l.871), `readPageLocation` (l.903), bookmarks (l.940-1017), `startReading`, chapter navigation (l.1023-1109), auto-scroll (l.1110-1147), speech (`speak` l.1148, `pushSpeechHighlight` l.1224, rate and voice), `navigateSpine` (l.1270), scrollbar visibility, `toggleReadingMode` (l.1310) and `toggleHostedReadingMode` (l.1359) |
| 1391-1410 | Toolbar title (`setToolbarTitle`) |
| 1411-1484 | TOC popup host (`toggleTOC`, `closeTOCPopup`) |
| 1485-1531 | Search host and context menu |
| 1532-1539 | Book Info sheet (`showBookInfo`) |
| 1540-1673 | Display settings: `applyDynamicSettings`, `applyCosmeticCSSUpdate`, `scheduleStructuralReload`, `adjustFontSize` |
| 1674-1873 | Progress reporting and position save and restore: `flushPositionSave`, `reportPaginatedProgress`, `didReceiveScrollPageInfo` |
| 1874-1925 | Navigation and key handling (`handleKeyDown`) |
| 1926-2083 | Scroll-wheel, key monitor and resize (paginated mode only) |
| 2084-2171 | Toolbar updates, helpers (`showLoading`, `showError`), toolbar actions (`showThemePopover`) |
| 2172-2356 | Delegate extensions: TOC navigation, `SearchBarDelegate`, `NSWindowDelegate`, `SpeechCoordinatorDelegate` |
| 2357-2435 | `WKNavigationDelegate` (link policy) |
| 2436-2662 | `NSToolbarDelegate`: default and allowed identifiers (l.2446-2461), `itemForItemIdentifier`, `makeToolbarButton` |
| 2663-2752 | Five private `WKScriptMessageHandler` classes (progress, position, page action, position update, page info) |
| 2753-2910 | `ReaderWebView` (key and context menu), toolbar identifier constants |

### `Parsing/EPUBParser.swift`
| Lines | Content |
|---|---|
| 1-291 | `EPUBParser`: `javaScriptStringLiteral`, `unpackEPUB`, `isDRMProtected(extractedRoot:)`, `parsePackage`, `searchResults`, `speechText`, `speechMap` (forwarders to `ChapterSearch`), `sanitizedLanguageTag`, `parseLandmarks` |
| 292-337 | Forwarders to `ReaderStyles` and `ReaderScripts` (`imageVisibilityCSS`, `paginatedColumnCSS`, `readerJS`, `monospaceStack`, `readerVarsCSS`, `readerCSS`) |

### `Settings/SettingsManager.swift`
| Lines | Content |
|---|---|
| 16-279 | `AppearanceMode`, `FontPreset(s)`, `ThemeColorSet`, `Theme`, `ThemeExport`, `ReadingMode`, `NewBookOpensIn` |
| 280-312 | Notification names, `SettingsManager.shared`, `themeStore`, `init(defaults:themeStore:)` |
| 313-342 | Font |
| 343-609 | Themes: cache over `ThemeStore`, one-time migration (`readerThemesMigratedToFiles`, l.464), `currentThemeID`, `currentTheme`, `effectiveColorSet`, `updateTheme`, `addTheme`, `deleteTheme` |
| 610-697 | Line height, font size, behaviour flags |
| 698-790 | Pagination; speech settings (`speechVoiceIdentifier`, `speechRate`, `speechHighlight`, `speechHighlightWord`, `speechFollow`, l.732-780) |
| 791-889 | Reading-column geometry (incl. `useThemeFontForCode`, `mutateCurrentTheme`, `applyAppearanceOverride`) |
| 890-1032 | Reset to defaults: `resetReaderToDefaults`, `resetAllToDefaults` |
| 1033-1073 | `notifyChange`, `notifyCosmeticChange`, `notifyStructuralChange`, color helpers |

### `Settings/SettingsWindowController.swift`
| Lines | Content |
|---|---|
| 36-165 | `SettingsPaneSizing`, `SettingsPaneMetrics` (fixed pane size), `SettingsWindowController`, `SettingsPanelWindow` |
| 166-307 | `SettingsTabViewController`: six tabs built from `tabSpecs` (General, Reading, Formatting, Appearance, History, Shortcuts; l.197-210) |
| 308-825 | `GeneralSettingsViewController`, `ReaderSettingsViewController` (the Reading tab: speech voice and rate, auto-scroll) |
| 826-2169 | `AppearanceSettingsViewController`: control factories (l.1090), visibility (l.1539), actions (l.1599), theme add, edit, duplicate, delete (l.1776, Open Themes Folder at l.956); field and control identity helpers (l.2039); `ThemeBigSwatchButton` (l.2062) |
| 2170-2333 | `HistorySettingsViewController`, table delegate, `HistorySettingsCellView` |
| 2334-2382 | `CustomFontStore`, `CustomFont` |

## Runtime wiring

| Mechanism | Names | Where |
|---|---|---|
| JS to Swift handlers | `progressHandler`, `positionHandler`, `pageInfoHandler` (from `readerJS`); `pageAction`, `positionUpdate` (from `PaginationJS`) | registered in `ReaderViewController.loadView`; handler classes at l.2663-2752 |
| Notifications | `readerCosmeticSettingsChanged`, `readerStructuralSettingsChanged`, `ReaderSettingsChanged` (`settingsChangedNotification`), `keyBindingsChanged`, `ReadingHistoryEntriesDidChange` | `SettingsManager`, `KeyBinding`, `HistoryManager` |
| UserDefaults keys | `reader*` settings keys, `appearanceMode`, `readerThemes`, `readerCurrentThemeID`, `readerKeyBindings`, `customSelectedFontID`, `readerThemesMigratedToFiles` (the old `readerThemes` blob stays as a rollback copy; themes live in files, `ThemeStore`), the speech keys `readerSpeechHighlight`, `readerSpeechHighlightWord`, `readerSpeechFollow` plus voice and rate, `HoneycrispReadingBookmarks.v1`, `EPUBReaderHistory` | `SettingsManager`, `KeyBinding`, `ReadingBookmark`, `HistoryManager`, `SettingsWindowController` |
| Open-book flow | `AppDelegate`/`ReaderWindowController` -> `ReaderViewController.loadEPUB` -> `DocumentImporter.importDocument` / `EPUBParser` -> `TOCParser.parseTOC` -> `HistoryManager.record` -> `FlowDocumentBuilder` -> `FlowSurface` (`honeycrisp-epub://book/__app/...`) | see `ARCHITECTURE.md` section 4 |

## Where do I change X

| Task | Start here |
|---|---|
| Add or change a menu item | `AppDelegate.setupMenus`; action in the Actions region; `validateMenuItem` |
| Add a rebindable shortcut | `RebindableAction` in `KeyBinding.swift`; `AppDelegate.syncMenuShortcuts`; `ShortcutsSettingsViewController` |
| Add a user setting | Property in `SettingsManager` (call `notifyCosmeticChange` or `notifyStructuralChange`); include in `resetReaderToDefaults` and `resetAllToDefaults`; control in the right pane in `SettingsWindowController` (or `FanfictionSettingsViewController` for the Formatting tab); if it affects rendering, extend `ReaderCosmeticSettings` and `readerVarsCSS` |
| Change reader typography or CSS | `ReaderStyles` (`readerVarsCSS`, `readerCSS`, `paginatedColumnCSS`), `ReaderCosmeticSettings`, `Theme` model. Note `readerCSS` ends with a universal `!important` rule that overrides color and background of anything without `!important` |
| Change how a chapter's HTML is cleaned | `ChapterPipeline`, `ChapterMarkup`, `ChapterTransforms`, `ChapterURLs` (any change shifts offsets: see CLAUDE.md invariants) |
| Page turning or column layout | `PaginationEngine`, `PaginationJS`, `ReaderViewController` scroll-wheel, key monitor and resize regions |
| Saved position and progress | `HistoryManager`, `RestorePosition`, `ReaderViewController` position save and restore region, `scrollRestoreBootstrapJS` |
| Table of contents or Start Reading | `TOCParser`, `Sidebar/TOC*`, `ReaderViewController` `toggleTOC` / `goToTOCEntry` |
| In-book search | `ChapterSearch.searchResults` (via `EPUBParser.searchResults`), `SearchBarViewController`, `ReaderViewController` `SearchBarDelegate` extension |
| Bookmarks | `BookmarkManager`, `ReaderViewController` bookmark functions (inside the EPUB Loading region), `AppDelegate` bookmark menu actions |
| Reading history UI | `HistoryViewController`, `HistoryEntryOpener`, `HistorySettingsViewController` |
| Toolbar buttons | `ReaderViewController` `NSToolbarDelegate` extension (`itemForItemIdentifier`, `makeToolbarButton`), identifier constants at end of file |
| Auto-scroll or speech | `SpeechCoordinator`, `SpeechTextMap`, `AVFoundationTTSEngine`, `SpeechProgress+JS`, `ReaderScripts` (`honeycrispSpeechHighlight`); `ReaderViewController` speech functions (l.1148-1269) and `SpeechCoordinatorDelegate` extension (l.2296); `MediaKeyCoordinator`; menu actions in `AppDelegate` |
| New DRM or parse error | `EPUBParseError`, `EPUBParser.isDRMProtected(extractedRoot:)` (called first by `parsePackage`); error surfaces via `showError` |
| Window behavior, float on top | `ReaderWindowController` (`setupWindow`, `toggleFloat`) |
| Themes | `Theme` and the cache in `SettingsManager`, file storage in `ThemeStore` and `ThemeFileCodec`, `AppearanceSettingsViewController`, `ThemePopoverViewController` |
| Open another file format | `BookFormat`, `DocumentImporter` and its importers, `Honeycrisp/Info.plist` document types |
| Book Info | `BookInfoViewController`, `ReaderViewController.showBookInfo`, `RebindableAction.bookInfo` |
| Link policy, script and URL restrictions | `FlowSurface` (`allowsContentJavaScript = false`, CSP, in-book link policy), `EPUBResourceSchemeHandler` (containment); `ChapterHostSurface` in flag mode; `ReaderViewController` `WKNavigationDelegate` extension |
| File type registration | `Honeycrisp/Info.plist`, `project.yml` settings |
| Signing, sandbox, version | `project.yml` base settings; workflows for release |

## Tests (`Tests/HoneycrispTests`, XCTest, synthetic fixtures)

| File | Covers |
|---|---|
| `ChapterDecoderTests.swift` | byte decoding (BOM, XML declaration, meta charset, UTF-8, windows-1252 fallback) |
| `ChapterMarkupTests.swift` | XML/HTML parsing, active content removal, serialization |
| `ChapterTextTests.swift` | entity decoding, supplementary characters, whitespace, hidden ranges |
| `ChapterTransformsTests.swift` | AO3 TOC heading and calibre2 bold styling, spacer paragraphs, preface heading hiding |
| `ChapterURLsTests.swift` | relative and root URL resolution, containment, fragment preservation, scheme preservation |
| `ChapterPipelineTests.swift` | end-to-end chapter render, active content removal, transform options, XML to HTML fallback |
| `ChapterPipelineConcurrencyTests.swift` | concurrent render byte identity to sequential, lowest index error rethrown, index order preservation |
| `ChapterPipelineThroughputTests.swift` | benchmark measurements written to pipeline-throughput.txt across single chapter, 300 chapters and 2,000 pages |
| `ChapterPipelineParityTests.swift` | WebKit TreeWalker text and marker offset parity across fixtures |
| `ChapterFixtures.swift` | synthetic test fixture definitions |
| `EPUBParserTests.swift` | package and spine parsing, landmarks, search offsets, JS string escaping, DRM rules (LCP file, LCP and ADEPT markers, unknown algorithm; font-obfuscation-only and empty manifests open), missing container, unpack |
| `TOCParserTests.swift` | NCX, EPUB3 XML nav, HTML5 SwiftSoup nav fallback, nested hierarchy, generic and numeric spine title synthesis, Start Reading, missing-TOC fallback |
| `TOCModelTests.swift` | tree hierarchy, pre-order traversal, spine and fragment resolution, title collapsing, expansion, type-to-filter |
| `TOCPopupViewControllerTests.swift` | prepareForDisplay current reveal and selection, type-to-filter, keyboard navigation (Return/Escape/Arrows), TOCPanel key window host resolution |
| `HistoryManagerTests.swift` | record, progress and position persistence, clamping, cap, clear, reload, bad-element survival, whole-blob quarantine, unreadable elements and the cap |
| `HistoryEntryTests.swift` | legacy decode defaults (including `anchorLayout`), round-trip of restore position and layout |
| `BookmarkManagerTests.swift` | per-book persistence, rename and remove, corrupt data isolation, bad-element survival, newer version and whole-blob quarantine, quarantine pruning, legacy bookmark decode, anchor layout round trip |
| `RestorePositionTests.swift` | fraction clamping, bootstrap call generation |
| `ReaderCSSSanitizerTests.swift` | hex normalization and injection rejection, preset and custom font stacks, length limits, numeric clamps, non-finite fallback |
| `ReaderContrastTests.swift` | contrast math, hit palette per page luminance, 4.5:1 floor for every seed theme, `--reader-hit-*` variables, no fixed yellow in `readerCSS` |
| `SettingsValueFormatTests.swift` | em, px and line-height labels, typed-number parsing, line-height range shared with the sanitizer, slider snap and clamp math |
| `ReaderStyleTests.swift` | `--reader-code-font-family` var and `readerCSS` rule, `useThemeFontForCode` default, persistence, reset; text alignment and hyphenation CSS (low specificity, off without a valid language), paragraph spacing and bold weight vars, spacer-paragraph rule, optional sanitized first-line indent |
| `LocatorTests.swift` | restore by offset when `layout` matches, by clamped fraction otherwise, Codable round trip, progress from text lengths or byte sizes, nil for paged or unknown resource |
| `EPUBResourceSchemeHandlerTests.swift` | scheme handler path containment (traversal and foreign schemes rejected), MIME mapping, `ActiveTaskSet` bookkeeping, root normalization, `/__app/` key rules (prefix, traversal, host, query), markup-only transform |
| `ServedChapterTests.swift` | `ServedChapter.prepare`: link before `</head>` (case-insensitive), head created when missing, self-closed head left alone, no `<html>` or non-UTF-8 unchanged, `lang` only when absent and only when safe, idempotent, body bytes unchanged, XML declaration and doctype stay first |
| `ChapterHostSpikeTests.swift` (spike, roadmap M3) | `WKWebView` through the scheme handler: self-closed anchors, nested relative images, class-only italic from book CSS, author script positive control and with content JS off, client-world scripts and message handlers, CSP header, `.html` served as XML, stopping a load mid-flight; outcomes are attachments to record in the roadmap |
| `ChapterHostCSSTests.swift` | pure `ChapterHostCSS`: user block always carries the variables, alignment, hyphenation and indent rules only when set, static stylesheet never touches book-owned properties, `!important` only on owned properties, reset in a low-priority layer; also the `ReaderCosmeticSettings.chapterHostFixture` used by the host tests |
| `ChapterHostCascadeTests.swift` | WebKit cascade through the handler: `@layer` support, class-only italics, centered verse under justified alignment, book alignment and indent kept at defaults, user font, color, size, line height, background, link color, width and padding, bold, small caps and underline untouched, oversized image contained, reset layer loses to book rules |
| `ChapterHostSurfaceTests.swift` | flag parsing, chapter URL encoding and containment (symlinked root), navigation policy, `install` and `attach`, missing chapter, WebKit: app-run script with content JS off, single chapter with book styles, user font and relative image, self-closed anchor, author script does not execute (positive control) |
| `ChapterHostShellTests.swift` | window indices clamped at book edges, shell HTML ordering, escaping, well-formed XML and no script, WebKit: three mounted chapters sized by the client-world script (assumption A1) and none clipped by its frame once the window has loaded, styles and duplicate ids isolated per frame, relative images in every frame |
| `ChapterHostWindowHarness.swift` | shared harness: temp synthetic book (optionally custom chapter XHTML, chapter count and viewport height), web view configured as the flag does, three-chapter window mounted, main-frame commit counter |
| `ChapterHostWindowingTests.swift` | slot shell and windowing (M4 pass 2): pure height estimate, slot attributes escaped and well-formed XML, no script, numeric restore attributes; WebKit on a 40-chapter book: one slot per spine item with only the window mounted, scrolling mounts the next chapter and evicts distant ones (at most 5), the chapter on the reference line is never evicted over 50 steps, an evicted slot keeps its height, reconcile settles; M4 pass 3: measuring a chapter above the viewport moves no visible text, measured height and running ratio replace estimates, 800-step walk across at least 20 boundaries is monotonic (diagnostics `m4-scroll-boundaries.txt`), a cosmetic patch keeps the chapter on screen stationary |
| `ChapterHostMessagingTests.swift` | V1 asserted: a client-world handler receives a post with content JS off; host position posts carry resource, offset and a chapter page within range, monotonic while scrolling; 50 scroll events post at most twice; malformed bodies ignored |
| `ChapterHostRestoreTests.swift` | `loadWindow(restoring:)`: shell hidden then revealed, `.start`, `.position` round trip through `firstVisiblePosition`, `.fraction`, no drift after the deferred re-fit, an unmounted far chapter is mounted first |
| `ChapterHostPagedTests.swift` | paged chapter on the host (M4 pass 6): paged block and bootstrap carry numbers only, `PaginationEngine` default stays on the page world, column CSS applies to the root and body width wins, class italics and centered verse survive, the pager runs in the client world with content JS off, `.start`/`.end`/`.fraction`/`.characterOffset` land on the expected column, page turns at chapter edges post `pageAction`, a cosmetic patch keeps columns and recounts, a second load replaces the first bootstrap |
| `ChapterHostPagingTests.swift` | pure `ChapterHostPaging` (M4 pass 7): hand-off forward to the next start and back to the previous end, nil at book edges, exact-offset restore, clamped fraction, geometry fallback, link-policy `changesDocument`, `pagedTarget`, `toPaged` and `toScroll` (mode toggle) |
| `ChapterHostPagedHandoffTests.swift` | chapter hand-off replayed on the surface: an edge page turn posts `pageAction`, the next chapter opens at column 0, the previous at its last column, forward then back returns to the same column |
| `ChapterHostPagedOffsetTests.swift` | `qlOffsetAtCurrentColumn` and `qlNavigateToOffset` round trip, zero on the first column and an empty chapter, the offset survives a font-size patch and a reload under new geometry |
| `ChapterHostPagedToggleTests.swift` | scroll window and pager count the same offset (U2): a shell position opens paged on the same text, a paged offset reopens the window on the same text |
| `ChapterHostCosmeticPatchTests.swift` | live patch (C8): all three mounted chapters change color and size with no navigation and no document reload, frames grow and shrink back, optional alignment rule appears and disappears, hostile payload stays inert text, chapters served later carry the new CSS, script is static and targets `ServedChapter.userStyleID` |
| `ChapterHostOffsetParityTests.swift` | host offsets (C2): per-chapter text-node-walk offsets equal `EPUBParser.searchResults` offsets for entities, a supplementary-plane character, whitespace and a self-closing anchor (not an expected failure, unlike the merged document); `scrollTo` then `firstVisiblePosition` round trip at three paragraph starts; unmounted chapter and past-the-end offset; script uses the shared walk definition |
| `WebKitOffsetParityTests.swift` | real `WKWebView` harness: offset parity (`XCTExpectFailure`, merged-document wrapper whitespace), known resource and link rewrite bugs (`XCTExpectFailure`), publisher class styles survive |
| `ReaderBaselineTests.swift` (baseline, roadmap M3) | generated synthetic books (250 and 2,000 nominal pages, 20 pages per chapter): merged-document path (`parsePackage`, `buildScrollHTML`, file write, `loadFileURL` plus forced layout) and chapter host path (`ChapterHostSurface.attach` and `loadWindow`, three mounted chapters, `scrollHeight` forced on each), 3 runs, medians, best-effort app and WebContent memory; asserts fixture sanity only (merged: chapter count and layout height; host: right three chapters, headings, heights, no `data-hc-error`); numbers go to `build/diagnostics/baseline-<pages>-pages.txt` and `host-<pages>-pages.txt`; M4 pass 5 adds `testHostScrollAcrossTwentyBoundariesTwoThousandPageBook` (in `ReaderBaselineScrollTests.swift`, an extension of this class that also holds `ScrollRunResult`; real client script, 20 boundaries, WebContent at most 30 MB, fails when the footprint is unreadable, numbers in `host-scroll-2000-pages.txt`) |
| `ReaderBaselinePagedTests.swift` (M4 pass 7.6) | paged memory: 20 consecutive chapters of the 2,000-page fixture reached through the real edge hand-off, median of each run's maximum WebContent footprint, at most 30 MB, writes `host-paged-2000-pages.txt` |
| `SyntheticBook.swift` | deterministic synthetic EPUB folder generator (nested `Text/` and `Styles/`, relative images, class-only italics), shared by the baseline tests |
| `Diagnostics.swift` | `TestDiagnostics.write(_:lines:)`: writes test measurements to `<repo>/build/diagnostics/` (gitignored); a failed write fails the test |
| `ChapterStylesTests.swift` | publisher CSS harvesting (Rule N3, Decision R21): property whitelist, discarded geometry and colors, simple selectors and combinators, cascade and source order, Rule N6 details/nav semantics, style tag stripping |
| `ChapterStylesIntegrationTests.swift` | publisher CSS integration: linked stylesheet resolution and file read, FicLab and AO3 real sample patterns, ChapterPipeline and FlowDocumentBuilder integration |
| `NavigationHistoryTests.swift` | navigation history stack (Decision R13): push, back, forward, truncation on new navigation, duplicate deduplication, bounded capacity |
| `FlowTOCNavigationTests.swift` | TOC and fragment navigation on flow surface: `hc-r{resource}-{id}` namespacing, fragment fallback, and smooth scroll into view |
| `FlowSpeechAndAutoScrollTests.swift` | speech text extraction and auto-scroll on flow surface: client-world execution, skipping script, style, and aria-hidden nodes |
| `FlowBookmarkTests.swift` | bookmarks on flow surface: chapter-scoped character offset calculation and bookmark restore |
| `FlowLinkNavigationTests.swift` | in-book anchor links: namespaced targets, cross-chapter navigation sync, navigation history recording for back-navigation |
| `FlowSurfaceTests.swift` | FlowSurface protocol conformance, link containment policy, CSP headers, user script injection, client-world message dispatch, environment flag controls |
| `FlowPositionTests.swift` | section-rooted position walk in WebKit, FlowSurface resource/offset dispatch, exact section seek, and position restore |
| `ChapterSearchTests.swift` | search and speech offsets with AO3 transforms, hidden preface and TOC heading filtering, double-encoded ampersand exactness, limit across chapters |
| `SpacerParagraphTests.swift` | spacer paragraphs tagged only when the setting is on, real paragraphs and `<pre>` untouched, text nodes unchanged, tag case kept |
| `AppDelegateInstallTests.swift` | the application delegate is `AppDelegate` (guards the launch regression where no window opened) |
| `BookFormatTests.swift` | format detection for EPUB, HTML, Markdown and plain text, unsupported extensions, supported types and extensions |
| `DocumentImporterTests.swift` | dispatch to the plain text, HTML, Markdown and directory EPUB importers; unsupported format throws |
| `PlainTextImporterTests.swift` | metadata and chapter splitting, numbered heading patterns, unstructured text chunking |
| `HTMLImporterTests.swift` | split by articles, split by headings, single unstructured document |
| `MarkdownImporterTests.swift` | front matter and headings, inline formatting |
| `FlowDocumentBuilderTests.swift` | per-resource id namespacing, same-chapter and cross-chapter link rewriting, app-scheme resource URLs, active content removed, valid section structure, paged document column CSS and no inline scripts |
| `FlowingSurfaceTests.swift` | `ChapterHostSurface` conformance to `FlowingSurface`: properties, paged restore target consumption, fallback when no restore is pending, did-finish handling |
| `ThemeFileCodecTests.swift` | round trip keeps `id`, `seedKey` honored only when recognized, corrupt data and unsupported version throw, slug generation, filename collisions |
| `ThemeStoreTests.swift` | first launch writes missing seeds, atomic custom theme write, rename removes the old file, slug collisions, delete removes the file, corrupt file preserved and not deleted |
| `BookInfoDescriptionTests.swift` | `cleanDescription`: tags stripped, named, numeric and hex entities decoded, whitespace collapsed |
| `BookmarkSnippetTests.swift` | snippet persists and decodes; a legacy bookmark without a snippet still decodes |
| `MediaKeyCoordinatorTests.swift` | setup registers targets once; now-playing info cleared when idle |
| `SpeechCoordinatorTests.swift` | voice filtering and quality sort, pluggable engine hand-off and progression, idle, start and stop, skip next and previous, chapter advance through the delegate, start from an offset inside a sentence |
| `SpeechTextMapTests.swift` | block breaks, minified blocks, hidden, aria-hidden, script and style skipped, whitespace mapping, sentence ranges, binary search of spoken index, abbreviations do not split |
| `SpeechStartResolverTests.swift` | selection, viewport and start modes, clamp past the end, empty sentences |
| `SpeechToolbarStateTests.swift` | toolbar state: unavailable without a book, idle, playing, paused |
| `SpeechProgressJSTests.swift` | generated highlight JS: sentence only, word and follow, word disabled, safe characters only |
| `SpeechSettingsTests.swift` | highlight, word and follow default on, persist, reset to defaults |
| `ReaderContrastSpeechTests.swift` | alpha hex sanitizer, color blend, speech colors are eight-digit hex, speech text keeps contrast on light and dark pages |
| `FlowSpeechHighlightTests.swift` | highlight texts match Swift-space offsets, clear removes boxes (loads only the variables block, never `readerCSS`, so it cannot see visibility defects) |
| `AVFoundationTTSEngineRangeTests.swift` | UTF-16 range handling: near the end of emoji text, combining sequences, out-of-bounds and not-found return nil |
| `SettingsManagerThemeTests.swift` | seed keys, Codable round trip, seed-key migration, reset and customized check by identity, delete protection (isolated `UserDefaults` suite) |

Not covered: `SettingsManager` beyond themes and speech, `KeyBinding`, `PaginationEngine` navigation,
`ReaderViewController`, search UI, all Settings panes, `AppDelegate` beyond the install check. The parity case in
`WebKitOffsetParityTests` is still an `XCTExpectFailure` although M4a is complete (roadmap 1.2 item 3).

## Docs map

| Doc | Use for | Caveat |
|---|---|---|
| `CLAUDE.md` | Rules, workflows (planning and implementation passes), invariants | Keep short; design lives in FRAMEWORK |
| `docs/FRAMEWORK.md` | Target design: layers, contracts (Locator, offsets, style cascade, trust), admission rules | Layers L0 to L3 are partly built (see its section 2 table); L0 PDF, CBZ, MOBI and `PagedSurface` are not |
| `docs/ROADMAP.md` | The only plan: decisions R1 to R24, milestones M0 to M10 with status, built and unbuilt table (1.1), known gaps (1.2), verify list, next work (7) | Plan; statuses come from reading code, not from a run |
| `ARCHITECTURE.md` | What the code does today, data flow, durability, settings persistence | Trust the code where they differ |
| `README.md` | Features, install, build | |
| `docs/compatibility-corpus.md` | Synthetic fixture to test mapping, real-file validation table | Static inspection table filled; on-device rows pending |
