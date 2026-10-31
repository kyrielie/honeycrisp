# Honeycrisp — Architecture

Native macOS EPUB reader. Pure AppKit + WebKit (`@main` on `AppDelegate`),
no SwiftUI. XcodeGen `project.yml` is the source of truth for the generated Xcode
project. The root Swift package is a secondary build entry point. macOS 13+.

This file describes what the code does today. The target design and its contracts are in
`docs/FRAMEWORK.md`; the plan, decisions and build status are in `docs/ROADMAP.md`. Book content is untrusted: in the default path
the flow surface turns author JavaScript off (`allowsContentJavaScript = false`), the content pipeline removes `<script>`, event attributes
and `javascript:` URLs, resources load only through the `honeycrisp-epub://` scheme handler, and responses carry a
`Content-Security-Policy` header. Whether WebKit enforces that header on the app scheme is on the roadmap verify list (Unverified).
The chapter host (flag mode, section 4a) enforces the same restrictions.

## 1. Project generation

`project.yml` defines the macOS app target, the ZIPFoundation and SwiftSoup dependencies, sandbox
entitlements, document type registration (EPUB, HTML, Markdown, plain text) and the shared `Honeycrisp` scheme. Run
`xcodegen generate` after changing it. Do not hand-edit the generated
`Honeycrisp.xcodeproj`. Release workflows generate the project before building.

## 2. Process shape

Single-process, multi-window. Each opened book gets its own
`ReaderWindowController` / `ReaderViewController` / `WKWebView`. There is no
document model shared across windows and no library/database. Persistent state is `UserDefaults`
(settings, key bindings, history through `HistoryManager`, per-book bookmarks through `BookmarkManager`) plus one JSON file per
theme in the app container (`ThemeStore`, section 5). This is a
deliberate scope boundary: Honeycrisp is a reader, not a library manager
(see `ambrosia` for that role).

```
AppDelegate (AppKit @main)               , app lifecycle, NSMenu, file-open routing
└── ReaderWindowController (N instances, one per open book)
        └── ReaderViewController          , WKWebView host, toolbar, keyboard/trackpad nav
            ├── DocumentImporter           , EPUB, plain text, HTML, Markdown into an EPUBPackage
            │   └── EPUBParser, TOCParser  , unzip, OPF/spine, TOC
            ├── FlowDocumentBuilder        , ChapterPipeline output into one flow or paged document
            ├── FlowSurface                , default surface: scheme handler, CSP, client-world scripts
            │   (ChapterHostSurface       , flag mode only, frozen)
            ├── PaginationEngine           , column-layout state machine (paginated mode)
            ├── SpeechCoordinator          , sentence queue, TTSEngine, highlight progress
            ├── TOCPopupViewController     , popup with type-to-filter
            └── SearchBarViewController    , in-book search overlay
    SettingsManager (singleton)            , UserDefaults-backed settings; theme cache over ThemeStore
    HistoryManager (singleton)             , UserDefaults-backed recent-files + position
    BookmarkManager (singleton)            , versioned per-book return points
    SettingsWindowController (singleton)   , App-menu Settings window
```

## 3. Module responsibilities

| File | Responsibility |
|---|---|
| `App/AppDelegate.swift` | Pure AppKit `@main` entry point; app lifecycle, all `NSMenu` construction, Apple-Event file-open handling, per-window vs per-tab open routing, live keybinding sync (`syncMenuShortcuts`), menu validation. |
| `Reader/ReaderWindowController.swift` | Per-window chrome: `NSWindow` creation, toolbar attach, float-on-top level/collectionBehavior, cascading placement, window-close → flush position save. |
| `Reader/ReaderViewController.swift` | The core reading surface: `WKWebView` configuration and message handlers, surface selection (`FlowSurface`, or `ChapterHostSurface` behind the flag), toolbar (`NSToolbarDelegate`), keyboard/scroll-wheel monitors for paginated mode, TOC popup host, search overlay host, bookmark, navigation-history and speech glue, cosmetic-vs-structural settings application, position save/restore, title display. |
| `Reader/FlowingSurface.swift` | L3 surface protocol (`FlowingSurface`, FRAMEWORK C5) isolating reading surfaces from shell logic; `ChapterHostSurface` and `FlowSurface` conformance. (Legacy merged document path deleted in M5). |
| `Reader/FlowDocumentBuilder.swift` | Multi-chapter flow document builder; namespaces element IDs, rewrites in-book links, resolves app-scheme URLs. |
| `Reader/FlowSurface.swift` | Flow surface implementation (default reading surface): renders continuous flow document under `honeycrisp-epub://`, disables author JS, isolates client-world scripts, section-rooted positions, and enforces CSP. |
| `Reader/ChapterHost*.swift`, `Reader/ServedChapter.swift` | Chapter host (flag mode, section 4a): `ChapterHostSurface`, `ChapterHostShell`, `ChapterHostScript` and its tail, `ChapterHostCSS`, `ChapterHostPaging`, `ChapterHostHandlers`; `ServedChapter.prepare` adds the host stylesheet and `lang`. |
| `Reader/EPUBResourceSchemeHandler.swift` | `honeycrisp-epub://book/...` scheme handler: path containment, MIME, optional response headers, `/__app/` app resources, markup transform hook. Serves `FlowSurface` and `ChapterHostSurface`. |
| `Reader/ReaderCosmeticSettings.swift` | Snapshot of reader cosmetics and hit color palette; pure Foundation and AppKit-free. |
| `Reader/ReaderStyles.swift` | Stylesheets, CSS variables (`readerVarsCSS`), image visibility, and multi-column CSS (`paginatedColumnCSS`). |
| `Reader/ReaderScripts.swift` | Injected client-world scripts (`readerJS`) for search, position, navigation, and speech. |
| `Reader/SpeechCoordinator.swift` | Coordinates text-to-speech playback, sentence queueing, pluggable `TTSEngine`, and progress notifications. |
| `Reader/SpeechProgress+JS.swift` | Generates client-world script calls for speech highlighting overlay updates. |
| `Reader/SpeechStartResolver.swift` | Pure Swift resolver mapping selection or viewport caret offsets to exact starting sentences. |
| `Reader/SpeechToolbarState.swift` | Pure state representation for the optional Speech toolbar button. |
| `Reader/TTS/TTSEngine.swift` | Protocol and voice descriptor definitions for speech synthesis backends. |
| `Reader/TTS/AVFoundationTTSEngine.swift` | Native `AVSpeechSynthesizer` implementation with UTF-16 code unit range handling. |
| `Reader/PaginationEngine.swift` | Drives `PaginationJS` from Swift: column navigation, fraction/offset restore, spine-boundary detection. |
| `Reader/PaginationJS.swift` | JS injected only in paginated mode: column-snap page turns, boundary detection posting back to `PageActionMessageHandler`. |
| `Reader/BookInfoViewController.swift` | Book Info sheet from parsed metadata; `cleanDescription` strips tags and decodes entities. |
| `Reader/MediaKeyCoordinator.swift` | System media keys and Now Playing through `MPRemoteCommandCenter`, wired to `SpeechCoordinator`. |
| `Parsing/BookFormat.swift` | File format detection enum (`BookFormat`), UTI definitions, file extension mappings, and format support queries. |
| `Parsing/DocumentImporter.swift` | Unified importation dispatcher (`DocumentImporter`, `DocumentImporterError`) converting EPUB, plain text, HTML, and Markdown files into `EPUBPackage` instances. |
| `Parsing/PlainTextImporter.swift` | Pure Foundation plain text importer: multi-encoding fallback, metadata extraction, chapter heading detection, scene break detection, and synthesized EPUB package generation. |
| `Parsing/HTMLDocumentImporter.swift` | Pure Foundation HTML importer: SwiftSoup parsing, active script/plugin stripping, article/heading chapter splitting, and synthesized EPUB package generation. |
| `Parsing/MarkdownImporter.swift` | Pure Foundation Markdown importer: CommonMark/GFM block parsing, YAML frontmatter extraction, heading chapter splitting, and synthesized EPUB package generation. |
| `Parsing/EPUBPackage.swift` | Publication data models (`EPUBPackage`, `EPUBManifestItem`, `EPUBSpineItem`, `EPUBLandmark`, `BookSearchResult`, `EPUBParseError`). |
| `Parsing/EPUBParser.swift` | Pure Foundation and ZIPFoundation parser (AppKit-free, WebKit-free): ZIP extraction, `container.xml` -> OPF -> manifest/spine/navigation/landmark parsing. |
| `Parsing/TOCParser.swift` | Manifest-declared EPUB3 nav, NCX (EPUB2), and synthesized spine fallback; preserves hierarchy and resolves Start Reading landmarks. |
| `Content/ChapterDecoder.swift`, `ChapterMarkup.swift`, `ChapterText.swift`, `ChapterTransforms.swift`, `ChapterURLs.swift`, `ChapterStyles.swift`, `ChapterPipeline.swift` | The one content pipeline (R20): byte decoding, SwiftSoup XML and HTML parsing with active-content removal, text extraction that matches the page script's text-node walk (C2), AO3 and spacer transforms, URL rewriting, publisher style harvest (R21), and the `ChapterPipeline` facade with concurrent `renderAll`. |
| `Content/ChapterSearch.swift` | Search indexing and speech text extraction over package chapters using `ChapterPipeline`. |
| `Content/SpeechTextMap.swift` | Bidirectional mapping between spoken sentences and chapter UTF-16 offsets with block-boundary preservation. |
| `Sidebar/TOCModel.swift` | Pure Swift model for TOC hierarchy, resolution, expansion, and filtering (`TOCLocation`, `TOCItem`, `TOCModel`). |
| `Sidebar/TOCPopupViewController.swift` | Modernized popup Table of Contents with type-to-filter search and keyboard navigation (`TOCPanel`, `TOCOutlineView`). |
| `Sidebar/SearchBarViewController.swift` | Centered in-book search overlay, debounced input, contextual excerpts, and navigable results. Search terms pass to WebKit as JSON string literals. |
| `Sidebar/ThemePopoverViewController.swift` | Toolbar gear-button quick theme switcher (Apple-Books-style popover). |
| `History/Locator.swift` | `Locator` (`.flow`, `.page`), `flowRestoreTarget` (exact offset when the saved layout matches `EPUBAnchor.currentLayout`, else clamped fraction), progress derivation. |
| `History/StorageQuarantine.swift` | Bounded raw copies of unreadable stored blobs, shared by history and bookmarks. |
| `History/NavigationHistory.swift` | Back and Forward navigation history stack (`NavigationLocation`, `NavigationHistoryStack`, Decision R13). |
| `History/HistoryManager.swift` | Singleton; `UserDefaults`-backed `[HistoryEntry]` — url, title, opened date, security-scoped bookmark, reading-progress percent, and a flow locator with offset, layout, and fraction fallback. |
| `History/ReadingBookmark.swift` | Codable bookmarks in an independently versioned `UserDefaults` envelope, separate from History. |
| `History/HistoryViewController.swift` | Popover list of recent books (open / remove actions). |
| `Settings/SettingsManager.swift` | Singleton; every user-facing setting, `UserDefaults`-backed except themes (no intermediate model object). Owns the `Theme` list (a cache over `ThemeStore`), font presets, reading-mode default, column count, appearance mode, speech voice, rate, highlight and follow, and posts `.readerCosmeticSettingsChanged` / `.readerStructuralSettingsChanged` / `SettingsManager.settingsChangedNotification` on mutation. |
| `Settings/SettingsWindowController.swift` | Six-tab Settings window (General / Reading / Formatting / Appearance / History / Shortcuts), all views built imperatively in `loadView()`; the Formatting tab is `FanfictionSettingsViewController`. |
| `Settings/ShortcutsSettingsViewController.swift` | Per-`RebindableAction` key-capture rows. |
| `Settings/ThemeStore.swift`, `Settings/ThemeFileCodec.swift` | Theme files (R19, M2.1): `ThemeStore` is the only theme file I/O, with an in-memory cache, debounced atomic writes, seed repair and rescan on activation; `ThemeFileCodec` is the pure encode, decode, slug and filename logic. |
| `Settings/FanfictionSettingsViewController.swift` | Formatting tab: Format for AO3, remove indents, collapse spacer paragraphs. |
| `Settings/ReaderContrast.swift`, `ReaderCSSSanitizer.swift`, `SettingsValueFormat.swift`, `ValueSliderControl.swift`, `ChapterTransformSettings.swift` | Pure contrast math and hit and speech palettes; validation of values interpolated into CSS; Appearance slider formatting and control; bridge from settings to `ChapterTransformOptions`. |
| `Settings/KeyBinding.swift` | `RebindableAction` enum + `KeyBinding` codable value type; defaults live here. |

## 3a. Behaviors kept on purpose

- `HistoryManager.record` carries `lastSpineIndex`, `lastCharacterOffset` and `anchorLayout` forward from the existing entry. Before this
  was fixed every open recorded the book first and then read back position `(0, 0)`, so saved positions were never restored. It is regression-tested.
- `removeFirstLine` and `enlargeSecondLine` settings were removed (nothing read them). Stale `readerRemoveFirstLine` and
  `readerEnlargeSecondLine` keys in `UserDefaults` are unread and harmless.
- `ReaderViewController.handleKeyDown` returns whether it handled the event, and `ReaderWindow.keyDown` and `ReaderWebView.keyDown` call
  `super.keyDown` when it did not, so stray keys keep AppKit's default behavior.

## 4. Data flow: opening a book

1. `AppDelegate.application(_:open:)` or `ReaderWindowController.showOpenPanel` gets a file `URL`; both filter by `BookFormat.isSupported`.
2. `ReaderViewController.loadDocument(at:)` calls `loadEPUB(at:)`, which starts security-scoped access and, off the main thread, calls
   `DocumentImporter.importDocument(at:to:)` into a work directory under Application Support. EPUB goes through `EPUBParser.unpackEPUB` and
   `parsePackage` (container.xml, OPF, `EPUBPackage`); plain text, HTML and Markdown importers synthesize an `EPUBPackage` with an NCX TOC. Then `TOCParser.parseTOC`.
3. Back on main, `finishLoading` publishes the package, works out where to open (saved `Locator` through `HistoryManager`, or past the cover), initializes the TOC model and reads
   the reading mode from `SettingsManager.shared.defaultReadingMode`.
4. `FlowDocumentBuilder` renders chapters inside `<section class="hc-chapter" id="hc-r{N}">`, served over `honeycrisp-epub://book/...` by `FlowSurface` for both continuous flow reading
   (`__app/flow.html`) and paginated mode (`__app/paged.html`).
5. `readerJS` (injected by `FlowSurface` in `WKContentWorld.defaultClient`) reports scroll, position and page information back to Swift through `WKScriptMessageHandler` handlers. In
   paginated mode, `PaginationJS` runs in `defaultClient` with a pager bootstrap that applies the column restore before revealing the page.

The reader is layered L1 to L3: `FlowDocumentBuilder` and `FlowSurface` render chapters with author JavaScript disabled, app scripts in the client world, and publisher styles
harvested by `ChapterStyles` (Rule N3 and N6, Decision R21). Navigation history (R13), TOC fragment navigation, bookmarks, speech and cross-chapter anchor navigation operate on
`FlowSurface`. The legacy merged-document path was removed in M5.

### 4a. Flag mode: chapter host (roadmap M3 and M4; off by default; frozen)

Status: frozen at roadmap M4 pass 7 (R20): bug fixes only; snapshot branch `chapter-engine` at 91c0dfd. It has no history, search, speech, bookmarks, TOC jumps or cross-chapter links, and it
is a read-only viewer. With `HONEYCRISP_CHAPTER_HOST=1` (set in the Xcode scheme, never persisted), `ReaderViewController` builds its web view through `ChapterHostSurface`.

- Structure: a script-free XHTML shell (`ChapterHostShell`, served as `__app/shell.html`) holds one `div.hc-slot` per spine item (height estimated from file size until measured).
  Only slots near the viewport hold an iframe, each served by `EPUBResourceSchemeHandler`. Author JavaScript is off, the book's own stylesheets are kept, `ChapterHostCSS` is the user
  layer, and navigation is restricted to the app scheme.
- Client script (`ChapterHostScript`, `WKContentWorld.defaultClient`): sizes each iframe (on load, right after, and when the shell's own load finishes), mounts and evicts on scroll and
  resize (mount margin 2 viewport heights, evict margin 4, at most 5 mounted, a slot on screen is never evicted, an evicted slot keeps its height), and replaces estimates with measured
  heights, scrolling by the difference when the slot lies above the reading line (`overflow-anchor: none`). It relies on app scripts running with content JavaScript off and reading
  same-scheme iframes (assumption A1, `ChapterHostShellTests`).
- Position: the script posts `{resource, offset, chapterPage, chapterPages}` (throttled to one post per 100 ms) to the handler `hostPosition`; `ChapterHostSurface.onPositionChange` hands it to
  `ReaderViewController.didReceiveHostPosition`, which updates the label (per chapter, R11). `honeycrispHost.offsetOfFirstVisibleText(x)` and `scrollTo(resource, offset)` (Swift:
  `firstVisiblePosition`, `scroll(to:in:)`) count offsets per chapter with the same text-node walk as the page script (C2). `loadWindow(restoring:)` opens on a chapter start, a text offset
  or a fraction; the shell stays hidden until the target frame is restored and re-fitted (a 2 s timer reveals it otherwise). A structural reload reopens at the current position in memory.
- Cosmetics: `applyCosmeticCSSUpdate` has a flagged branch that calls `ChapterHostSurface.applyCosmetics`, which updates the CSS served to chapters mounted later and replaces the text of
  `<style id="honeycrisp-user">` in every mounted chapter (`honeycrispHost.applyUserCSS`, the CSS passed as a `callAsyncJavaScript` argument and assigned as text), then re-fits the frames. No reload.
- Paged mode: `ChapterHostSurface.loadPaged` serves one chapter as the top-level document with column CSS (`ReaderStyles.paginatedColumnCSS`, wrapped by `ChapterHostCSS.pagedBlock`) and the shared
  `PaginationJS` as a client-world script (`pagerBootstrap` runs on the window `load` event so the column count is read from the settled layout). `PaginationEngine(webView:contentWorld:)` drives it;
  `pageAction` and `positionUpdate` are registered in the client world. `PaginationJS.qlOffsetAtCurrentColumn` returns the offset of the first text on the current page, so a cosmetic patch, a
  resize or a structural change reopens at the same text. `navigateSpine` hands off at chapter edges through `ChapterHostPaging.handoff` (next chapter at its first column, previous at its last;
  ignored while a chapter loads). A link activation that would change the document is cancelled while paged (`ChapterHostPaging.changesDocument`).
  `toggleReadingMode` has a flag branch (`toggleHostedReadingMode`) that converts exact offsets in both directions (`ChapterHostPaging.toPaged`, `toScroll`).
- Persistence: flag mode never writes to `HistoryManager` or `BookmarkManager`. `flushPositionSave`, the position capture in `scheduleStructuralReload` and `toggleBookmarkAtCurrentPosition`
  return early, because their JS queries fall back to offset 0 when the page script is absent. A paged open or hand-off restores from an in-memory `Restore` only.
- Offsets in flag mode are over raw chapter bytes and equal pipeline text only for chapters without active content.

## 5. Settings persistence model

`SettingsManager` is a direct `UserDefaults` wrapper: every property is a computed `get`/`set` pair on a `UserDefaults` key, with no separate serialized settings object. Themes are the exception
(R19, M2.1). Each theme is one JSON file, `<slug>.honeycrisp-theme.json` in the `ThemeExport` shape, in `Application Support/Honeycrisp/Themes` inside the app container.
`ThemeStore` is the only type that touches those files; it keeps an in-memory cache, writes changed files atomically after a 250 ms trailing debounce, flushes on
`applicationWillTerminate`, regenerates missing seed themes, skips unreadable or newer-version files without rewriting them, and rescans on app activation and when Appearance opens
(`rescanIfChanged`). `SettingsManager.themes` returns the cache and its setter writes through the store, so mutation call sites did not change. On first launch after the upgrade the
existing migration chain runs once and writes every file, guarded by the flag `readerThemesMigratedToFiles`; the old `readerThemes` blob is left in `UserDefaults` as a rollback copy.
`readerCurrentThemeID` stays in `UserDefaults`. `KeyBinding` values are `Codable` blobs under `readerKeyBindings`. Legacy-key migration (for example `migrateLegacyFontFamily`,
`migrateLegacyThemes`) runs inline at read time.

## 5a. Stored data durability and anchor layout

Storage durability. `HistoryManager` (bare `[HistoryEntry]` array) and `BookmarkManager` (versioned envelope) decode element by element. An element that fails to decode is kept as raw JSON and written back on the next save, so one bad element never wipes the rest. A blob that is not readable at all, or a bookmark envelope with a version other than the supported one, is first copied to `<key>.quarantine.<unix-seconds>` by `StorageQuarantine` (newest 3 kept), before the first overwrite. Loading alone never writes. In history, unreadable elements count toward `maxEntries` and are dropped first; `clearAll` removes them too.

Anchor layout. Saved character offsets are only valid for the text extraction that produced them. `EPUBAnchor.currentLayout` (`Reader/PaginationEngine.swift`) is stored as `anchorLayout` on `HistoryEntry` and `ReadingBookmark`; data without the field decodes as `EPUBAnchor.legacyLayout` (1). Rule: bump `currentLayout` whenever a change alters character offsets, meaning anything touching `ChapterPipeline`, `ChapterText`, or the chapter transforms. M6 bumped `currentLayout` from 1 to 2 when moving the content pipeline to SwiftSoup (hidden instead of removed preface heading and AO3 TOC heading, whitespace exactness, URL resolution). `Locator` restores layout-2 offsets exactly by character offset, falling back to fraction for legacy layout 1 entries. `HistoryManager.record` carries `anchorLayout` forward with the position it describes; only `updatePosition` re-stamps it. The "Collapse empty spacer paragraphs" setting (`SettingsManager.collapseSpacerParagraphs`, key `readerCollapseSpacerParagraphs`, default off) adds a `ql-spacer` class in `ChapterTransforms`; `readerCSS` zeroes the box height. Text nodes are kept, so it does not alter offsets, search or speech text, and needs no `currentLayout` bump.

## 6. Known non-goals (intentional, not gaps)

- No library/catalog view — File > Open / drag-drop / Open Recent / explicit bookmarks only.
- No cross-book full-text search — `SearchBarViewController` is in-book only.
- Publisher stylesheets are not loaded in the default flow surface: the pipeline harvests a small whitelist of simple rules into inline attributes (R21) and strips raw `<style>` elements. The chapter host (flag mode) keeps the book's styles (R1). See `docs/FRAMEWORK.md` C4.
- No per-window/per-book reading mode override — `currentMode` always initializes from the global `SettingsManager.shared.defaultReadingMode`.

## 7. Known gaps

Current, prioritized gaps are in `docs/ROADMAP.md` sections 1.2 and 7. Notes kept here because the code does not explain them:

- **DRM**: `EPUBParser.isDRMProtected` detects real markers (LCP, ADEPT, non-font encryption algorithms) and `parsePackage` throws `EPUBParseError.drmProtected`; font obfuscation alone is not DRM.
- **Calibre annotations**: not supported (read or write). Calibre keeps highlights in its own library metadata, not in the EPUB, so a standalone-opened EPUB generally carries none. Needs a real sample
  before a parser is written; when built it would be read-only, enforced in code.
- **Quote sharing**: not planned (roadmap section 5).
- **Speech**: `SpeechCoordinator` queues sentences from `SpeechTextMap` (C2-parity offsets, block breaks, hidden text skipped) through a pluggable `TTSEngine` (`AVFoundationTTSEngine`). The highlight is an
  absolutely positioned overlay (`#hc-speech-hl`) appended to `document.documentElement`, so book content is never mutated. Speech starts from the selection or the first visible sentence, follows
  along in scroll and paged modes, and advances across chapters. The overlay colors are likely overridden by the universal `!important` rule in `readerCSS` (roadmap 1.2 item 1).
- **Window state restoration**: `ReaderWindowController.setupWindow` sets `isRestorable = false`.

## 8. Decisions carried over from the revision plan

- **Per-window/per-book reading-mode override**: audited, confirmed already absent from the code (`ReaderViewController.currentMode` and `HistoryEntry` both already have no per-book mode field) — closed with no code change, documented here so it stops being re-flagged as missing.
- **Non-goals** (no library view, no cross-book search) are confirmed intentional and listed in the README. "No publisher styling" was dropped as a non-goal by roadmap decision R1; quote sharing is parked in the roadmap.

## 9. Settings window: per-tab resize is wired but inert (by design)

The original Settings-window rebuild plan (since removed) called the animated
per-tab resize (a `SettingsPaneSizing` protocol, `resolvePreferredPaneSize()`,
`SettingsPanelWindow.setWindowSize`, per-tab size caching) "the main
structural gap" and "the core structural change." All of that machinery is
present in `SettingsWindowController.swift` and is correctly wired to
`SettingsTabViewController.tabView(_:didSelect:)`.

It has no visible effect: every pane's `loadView()` constructs its root
`NSView` with `frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size)`
(the same fixed 520×560 constant, `SettingsPaneMetrics.size`, for every tab) so `resolvePreferredPaneSize()` always resolves to the same
size for all six tabs and the animated resize path never actually
resizes anything. This is intentional (see the doc comment on
`SettingsPaneMetrics`: a prior version *did* size per-tab and that read as
unwanted "responsive" resizing), but the plan document was never updated to
reflect the reversal, so it still reads as if per-tab resize is live
behavior. Treat that plan as superseded by this section, not as current behavior. Not changed in code —
this is a deliberate product decision, not a bug, so it's left as-is with
the documentation now caught up to it.

## 10. Settings and AppKit entry point

An earlier `Sources/App/EPUBReaderApp.swift` declared a SwiftUI `Settings` scene alongside `AppDelegate.setupMenus()`. In release builds, the SwiftUI `@main` lifecycle interfered with menu management by overwriting `NSApp.mainMenu` and intercepting ⌘, with its `Settings` scene (displaying a blank window).

Fixed: The SwiftUI `@main` shim (`EPUBReaderApp.swift`) is removed. `AppDelegate` is the direct `@main` entry point with an explicit `@MainActor static func main()` that instantiates and strongly retains `AppDelegate`, sets `NSApp.delegate`, and starts the run loop (`app.run()`). Because Honeycrisp has no nib or storyboard, this explicit programmatic bootstrap is required so AppKit invokes `applicationWillFinishLaunching` and `applicationDidFinishLaunching`, leaving `AppDelegate.setupMenus()` and `SettingsWindowController.shared` in full control of macOS menu bar population and settings window presentation.
