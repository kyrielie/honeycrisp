# Honeycrisp — Architecture

Native macOS EPUB reader. AppKit + WebKit, no SwiftUI beyond the `@main` boot
shim. XcodeGen `project.yml` is the source of truth for the generated Xcode
project. The root Swift package is a secondary build entry point. macOS 13+.

This file describes what the code does today. The target design and its contracts are in
`docs/FRAMEWORK.md`; the plan and decisions are in `docs/ROADMAP.md`. In the default path (until roadmap milestone M4a, R20),
book scripts and resource URLs are not restricted: `allowsContentJavaScript` is `true` and chapter
bodies keep `<script>` and event attributes. Flag mode (4a) restricts them.

## 1. Project generation

`project.yml` defines the macOS app target, ZIPFoundation dependency, sandbox
entitlements, document type registration, and shared `Honeycrisp` scheme. Run
`xcodegen generate` after changing it. Do not hand-edit the generated
`Honeycrisp.xcodeproj`. Release workflows generate the project before building.

## 2. Process shape

Single-process, multi-window. Each opened book gets its own
`ReaderWindowController` / `ReaderViewController` / `WKWebView`. There is no
document model shared across windows and no library/database — the app's
only persistent state is `UserDefaults` (settings, theme list, key bindings),
history (`HistoryManager`), and independent per-book bookmarks (`BookmarkManager`). This is a
deliberate scope boundary: Honeycrisp is a reader, not a library manager
(see `ambrosia` for that role).

```
EPUBReaderApp (SwiftUI @main, boots AppDelegate)
└── AppDelegate                          — app lifecycle, NSMenu, file-open routing
    └── ReaderWindowController (N instances, one per open book)
        └── ReaderViewController          — WKWebView host, toolbar, keyboard/trackpad nav
            ├── EPUBParser                 — unzip, OPF/spine parse, HTML+CSS build
            ├── TOCParser                  — NCX / nav.xhtml / spine-synthesis
            ├── PaginationEngine           — column-layout state machine (paginated mode)
            ├── TOCPopupViewController     — popup with type-to-filter
            └── SearchBarViewController    — in-book search overlay
    SettingsManager (singleton)            — UserDefaults-backed settings/themes
    HistoryManager (singleton)             — UserDefaults-backed recent-files + position
    BookmarkManager (singleton)            — versioned per-book return points
    SettingsWindowController (singleton)   — App-menu Settings window
```

## 3. Module responsibilities

| File | Responsibility |
|---|---|
| `App/EPUBReaderApp.swift` | SwiftUI `@main` entry point; immediately hands off to `AppDelegate`. |
| `App/AppDelegate.swift` | App lifecycle, all `NSMenu` construction, Apple-Event file-open handling, per-window vs per-tab open routing, live keybinding sync (`syncMenuShortcuts`), menu validation. |
| `Reader/ReaderWindowController.swift` | Per-window chrome: `NSWindow` creation, toolbar attach, float-on-top level/collectionBehavior, cascading placement, window-close → flush position save. |
| `Reader/ReaderViewController.swift` | The core reading surface: `WKWebView` configuration and message handlers, toolbar (`NSToolbarDelegate`), keyboard/scroll-wheel monitors for paginated mode, TOC popup host, search overlay host, cosmetic-vs-structural settings application, position save/restore, title display. |
| `Reader/FlowingSurface.swift` | L3 surface protocol (`FlowingSurface`, FRAMEWORK C5) isolating reading surfaces from shell logic; `ChapterHostSurface` and `FlowSurface` conformance. (Legacy merged document path deleted in M5). |
| `Reader/FlowDocumentBuilder.swift` | Multi-chapter flow document builder; namespaces element IDs, rewrites in-book links, resolves app-scheme URLs. |
| `Reader/FlowSurface.swift` | Flow surface implementation (default reading surface): renders continuous flow document under `honeycrisp-epub://`, disables author JS, isolates client-world scripts, section-rooted positions, and enforces CSP. |
| `Reader/ReaderCosmeticSettings.swift` | Snapshot of reader cosmetics and hit color palette; pure Foundation and AppKit-free. |
| `Reader/ReaderStyles.swift` | Stylesheets, CSS variables (`readerVarsCSS`), image visibility, and multi-column CSS (`paginatedColumnCSS`). |
| `Reader/ReaderScripts.swift` | Injected client-world scripts (`readerJS`) for search, position, navigation, and speech. |
| `Reader/PaginationEngine.swift` | Drives `PaginationJS` from Swift: column navigation, fraction/offset restore, spine-boundary detection. |
| `Reader/PaginationJS.swift` | JS injected only in paginated mode: column-snap page turns, boundary detection posting back to `PageActionMessageHandler`. |
| `Parsing/BookFormat.swift` | File format detection enum (`BookFormat`), UTI definitions, file extension mappings, and format support queries. |
| `Parsing/DocumentImporter.swift` | Unified importation dispatcher (`DocumentImporter`, `DocumentImporterError`) converting EPUB, plain text, HTML, and Markdown files into `EPUBPackage` instances. |
| `Parsing/PlainTextImporter.swift` | Pure Foundation plain text importer: multi-encoding fallback, metadata extraction, chapter heading detection, scene break detection, and synthesized EPUB package generation. |
| `Parsing/HTMLDocumentImporter.swift` | Pure Foundation HTML importer: SwiftSoup parsing, active script/plugin stripping, article/heading chapter splitting, and synthesized EPUB package generation. |
| `Parsing/MarkdownImporter.swift` | Pure Foundation Markdown importer: CommonMark/GFM block parsing, YAML frontmatter extraction, heading chapter splitting, and synthesized EPUB package generation. |
| `Parsing/EPUBPackage.swift` | Publication data models (`EPUBPackage`, `EPUBManifestItem`, `EPUBSpineItem`, `EPUBLandmark`, `BookSearchResult`, `EPUBParseError`). |
| `Parsing/EPUBParser.swift` | Pure Foundation and ZIPFoundation parser (AppKit-free, WebKit-free): ZIP extraction, `container.xml` -> OPF -> manifest/spine/navigation/landmark parsing. |
| `Parsing/TOCParser.swift` | Manifest-declared EPUB3 nav, NCX (EPUB2), and synthesized spine fallback; preserves hierarchy and resolves Start Reading landmarks. |
| `Content/ChapterSearch.swift` | Search indexing and speech text extraction over package chapters using `ChapterPipeline`. |
| `Sidebar/TOCModel.swift` | Pure Swift model for TOC hierarchy, resolution, expansion, and filtering (`TOCLocation`, `TOCItem`, `TOCModel`). |
| `Sidebar/TOCPopupViewController.swift` | Modernized popup Table of Contents with type-to-filter search and keyboard navigation (`TOCPanel`, `TOCOutlineView`). |
| `Sidebar/SearchBarViewController.swift` | Centered in-book search overlay, debounced input, contextual excerpts, and navigable results. Search terms pass to WebKit as JSON string literals. |
| `Sidebar/ThemePopoverViewController.swift` | Toolbar gear-button quick theme switcher (Apple-Books-style popover). |
| `History/NavigationHistory.swift` | Back and Forward navigation history stack (`NavigationLocation`, `NavigationHistoryStack`, Decision R13). |
| `History/HistoryManager.swift` | Singleton; `UserDefaults`-backed `[HistoryEntry]` — url, title, opened date, security-scoped bookmark, reading-progress percent, and a flow locator with offset, layout, and fraction fallback. |
| `History/ReadingBookmark.swift` | Codable bookmarks in an independently versioned `UserDefaults` envelope, separate from History. |
| `History/HistoryViewController.swift` | Popover list of recent books (open / remove actions). |
| `Settings/SettingsManager.swift` | Singleton; every user-facing setting, all directly `UserDefaults`-backed (no intermediate model object, no persistence layer). Owns the `Theme` list, font presets, reading-mode default, column count, appearance mode, and posts `.readerCosmeticSettingsChanged` / `.readerStructuralSettingsChanged` / `SettingsManager.settingsChangedNotification` on mutation. |
| `Settings/SettingsWindowController.swift` | Five-tab Settings window (General / Reading / Appearance / History / Shortcuts), all views built imperatively in `loadView()`. |
| `Settings/ShortcutsSettingsViewController.swift` | Per-`RebindableAction` key-capture rows. |
| `Settings/KeyBinding.swift` | `RebindableAction` enum + `KeyBinding` codable value type; defaults live here. |

## 3a. Fixed bug: saved reading position previously never restored

`ReaderViewController.loadEPUB(at:)` calls `HistoryManager.shared.record(url:title:)`
(which logs the just-opened book into history) *before* it reads
`HistoryManager.shared.savedPosition(for:)` to decide where to restore to —
in both the paginated-mode branch and, via `scrollRestoreBootstrapJS()`, the
scroll-mode path. `HistoryManager.record` used to unconditionally replace the
`HistoryEntry` for that URL with a fresh one whose initializer hardcodes
`lastSpineIndex`/`lastCharacterOffset` to `0` (only `readingProgressPercent`
carried forward), so the later `savedPosition(for:)` lookup always read back
`(0, 0)` for the book that was just opened — every open silently discarded
the saved position before it was ever consulted. Fixed by having `record()`
carry `lastSpineIndex`/`lastCharacterOffset` forward from the existing entry
the same way it already carried `readingProgressPercent` forward, so the
fix holds regardless of call order at any future call site.

## 3b. Removed dead settings: `removeFirstLine` / `enlargeSecondLine`

`SettingsManager` used to expose `removeFirstLine`/`enlargeSecondLine` as
fully `UserDefaults`-backed properties, included in `resetAllToDefaults()`,
but nothing in `EPUBParser`'s HTML-building path ever read either one and no
Settings pane exposed a control for either — leftover sub-flags from before
"Format for AO3" (`formatFirstChapter`) absorbed their behavior. Removed;
any stale `readerRemoveFirstLine`/`readerEnlargeSecondLine` keys left in a
user's `UserDefaults` from a prior build are now simply unread, which is
harmless.

## 3c. Fixed: ReaderWindow no longer swallows unhandled key events

`ReaderWindow.keyDown` unconditionally routed every keystroke to
`ReaderViewController.handleKeyDown(_:)` whenever a reader VC was the
content view controller, and `handleKeyDown`'s `switch` had a no-op
`default: break` — so any key outside its five explicit cases (arrows,
Page Up/Down, ⌘F) was silently swallowed at the window level instead of
falling through to `super.keyDown(with:)`, losing AppKit's default
"no responder handled this" behavior (e.g. the system beep) for stray
keys. `handleKeyDown` now returns whether it actually handled the event,
and both callers (`ReaderWindow.keyDown`, `ReaderWebView.keyDown`) fall
back to `super.keyDown(with:)` when it didn't.

## 4. Data flow: opening a book

1. `AppDelegate.application(_:open:)` or `ReaderWindowController.showOpenPanel` gets a file `URL`.
2. `ReaderViewController.loadEPUB(url:)` starts security-scoped access, then off the main thread:
   `EPUBParser.unpackEPUB` (ZIP → temp dir) → `EPUBParser.parsePackage` (container.xml → OPF → `EPUBPackage`) → `TOCParser.parseTOC`.
3. Back on main: `HistoryManager.record`, TOC model initialized, reading mode read from `SettingsManager.shared.defaultReadingMode`.
4. `FlowDocumentBuilder` renders chapters inside `<section class="hc-chapter" id="hc-r{N}">` served over `honeycrisp-epub://book/...` via `FlowSurface` for both continuous flow reading (`__app/flow.html`) and paginated mode (`__app/paged.html`).
5. `readerJS` (injected via `FlowSurface` in `WKContentWorld.defaultClient`) reports scroll, position, and page information back to Swift via `WKScriptMessageHandler` handlers. In paginated mode, `PaginationJS` runs in `defaultClient` alongside a pager bootstrap script that applies column restore before revealing the page.

The reader architecture is layered across L1-L3: `FlowDocumentBuilder` and `FlowSurface` render chapters served over `honeycrisp-epub://book/...` with author JavaScript disabled, app scripts in `WKContentWorld.defaultClient`, and publisher styles harvested via `ChapterStyles` (Rule N3/N6, Decision R21). The legacy merged document path (`buildScrollHTML` and `LegacyMergedSurface`) was completely removed in Milestone M5. Under milestone M5, navigation history (Decision R13), TOC fragment navigation, bookmarks, speech, and cross-chapter anchor navigation operate directly on `FlowSurface`.

### 4a. Flag mode: chapter host spike (roadmap M3; off by default)

Status: frozen at roadmap M4 pass 7 (R20). The code stays behind the flag, bug fixes only; the snapshot is branch `chapter-engine` at 91c0dfd. It is not the default and has no history, search, speech or bookmarks.


With the environment variable `HONEYCRISP_CHAPTER_HOST=1`, `ReaderViewController` builds its web view through `ChapterHostSurface` and scroll mode shows the chapter at `activeScrollSpineIndex` and its neighbours (a window of up to three) as isolated documents: a script-free XHTML shell (`ChapterHostShell`, served as the `__app/shell.html` app resource) holds one iframe per chapter, each served by `EPUBResourceSchemeHandler` at `honeycrisp-epub://book/...`. Author JavaScript is off for the whole web view, the book's own stylesheets are kept, `ChapterHostCSS` is the user layer, and links and navigation are restricted to the app scheme. One app script, `ChapterHostScript`, runs in the client world (`WKContentWorld.defaultClient`) and sizes each iframe to its chapter (on load, again right after, and when the shell's own load finishes, because a first measurement can precede style application); this relies on app scripts running with content JavaScript off and reading same-scheme iframes (assumption A1 in the M3 plan, tested by `ChapterHostShellTests`). Cosmetic setting changes patch live: `applyCosmeticCSSUpdate` has a flagged branch that calls `ChapterHostSurface.applyCosmetics`, which updates the CSS served to chapters mounted later and replaces the text of `<style id="honeycrisp-user">` in every mounted chapter document through the client world (`honeycrispHost.applyUserCSS`, the CSS passed as a `callAsyncJavaScript` argument, assigned as text only), then re-fits the frames; no reload. The client script also exposes `honeycrispHost.offsetOfFirstVisibleText(x)` and `scrollTo(resource, offset)` (Swift: `ChapterHostSurface.firstVisiblePosition` and `scroll(to:in:)`), positions as `{resource, offset}` with offsets counted per chapter document by the same body text-node walk as the merged script (contract C2); nothing in the reader calls them yet (position save and restore is M5). The shell holds one `div.hc-slot` per spine item (height estimated from the file size until the chapter is measured); only slots near the viewport hold an iframe, and `ChapterHostScript.reconcile` mounts and evicts on scroll and resize (mount margin 2 viewport heights, evict margin 4, at most 5 mounted, a slot on screen is never evicted, an evicted slot keeps its height). The first load does not reconcile, and the shell opens on the first mounted chapter. A measured chapter height replaces the estimate, and when the slot lies above the reading line (a third down the window) the script scrolls by the difference in the same JS turn (`overflow-anchor: none` on the shell); a frame still showing its initial `about:blank` document is never measured, and until the first position is established an empty slot at the window top does not count as above; a running px-per-byte ratio re-estimates unmeasured slots the same way. The script posts the reading position (`{resource, offset, chapterPage, chapterPages}`, throttled to one post per 100 ms) to the client-world handler `hostPosition`; `ChapterHostSurface.onPositionChange` hands it to `ReaderViewController.didReceiveHostPosition`, which updates `activeScrollSpineIndex`, the current chapter and the label (per chapter, `page/pages chapter/count`, same format as paginated mode, roadmap R11). `loadWindow(restoring:)` opens on a chapter start, a text offset or a fraction: the shell is hidden by a body attribute until the script has restored after the target frame loaded and was re-fitted (the target is placed again when the shell's own load finishes, and the reveal waits for that; a 2 s timer reveals it if nothing reports); a structural reload reopens at the current position in memory. Still nothing is saved or read from history. It is a read-only viewer. Not ported (M4, M5, M6): position save and restore, progress, search, speech, bookmarks, TOC jumps, cross-chapter links, AO3 and indent transforms, hide images, spacer collapsing (paginated mode is ported, see below). `ChapterHostSurface.loadPaged` serves one chapter as the top-level document with column CSS (`EPUBParser.paginatedColumnCSS`, wrapped by `ChapterHostCSS.pagedBlock`, appended to the user block so cosmetic patches keep it) and the shared `PaginationJS` as a client-world script (`pagerBootstrap`: setup, restore, reveal, all run on the window `load` event so the column count is read from the settled layout; scripts are re-added before every load); `PaginationEngine(webView:contentWorld:)` drives it through `callAsyncJavaScript`, and `pageAction` and `positionUpdate` are registered in the client world. `PaginationJS.qlOffsetAtCurrentColumn` returns the offset of the first text on the current page (the inverse of `qlNavigateToOffset`, same text-node walk, no DOM mutation), and a cosmetic patch of a paged chapter seeks back to that offset after recounting columns, so the text being read stays on screen (fraction only when the chapter has no text on or after the page). In flag mode paginated mode now uses it: `ReaderViewController.loadSpineItem` delegates to `loadHostedPagedChapter` (geometry from `ChapterHostPaging.geometry`, `PaginationEngine(webView:contentWorld: .defaultClient)`), `navigateSpine` hands off at chapter edges through `ChapterHostPaging.handoff` (next chapter at its first column, previous at its last; ignored while the engine is not ready, i.e. while a chapter loads), and `webView(_:didFinish:)` reads the layout back with `applyLayout`, which retries while the pager's own setup has not yet run on `load`. A paged open or hand-off restores from an in-memory `Restore` only (`ChapterHostPaging.pagedTarget`), never from history, and `didReceiveProgress` writes nothing in flag mode. A resize (only when the geometry changed) or a structural setting change reopens the chapter at the offset of the first text on the page (`PaginationEngine.currentOffset`, in memory only), and a link activation that would change the document is cancelled while paged (`ChapterHostPaging.changesDocument`; cross-chapter links are M5, same-document fragments are left alone). `toggleReadingMode` has a flag branch (`toggleHostedReadingMode`): scroll to paged reads the text on the window's reference line (`firstVisiblePosition`) and opens the paged chapter at that exact offset (`ChapterHostPaging.toPaged`), paged to scroll reopens the window at `PaginationEngine.currentOffset` (`ChapterHostPaging.toScroll`); both counts use the same body text-node walk (contract C2), nothing is read from or written to history, and a toggle while a chapter is loading (engine not ready) reopens that chapter at its start. Flag mode never writes to `HistoryManager` or `BookmarkManager`: `flushPositionSave`, the position capture in `scheduleStructuralReload` and `toggleBookmarkAtCurrentPosition` return early, because their JS queries fall back to offset 0 when the page script is absent. With the flag unset nothing changes. Note: flag mode offsets are over raw chapter bytes and equal pipeline text only for chapters without active content.

## 5. Settings persistence model

`SettingsManager` is a thin, direct `UserDefaults` wrapper — every property is a computed `get`/`set` pair reading/writing a `UserDefaults` key, with no separate serialized settings object and no export/import path. `Theme` and `KeyBinding` values are `Codable` and stored as encoded `Data` blobs under single keys (`themes`, key-binding dictionary). Legacy-key migration (e.g. `migrateLegacyFontFamily`, `migrateLegacyThemes`) is handled inline, per-property, at read time.

## 5a. Stored data durability and anchor layout

Storage durability. `HistoryManager` (bare `[HistoryEntry]` array) and `BookmarkManager` (versioned envelope) decode element by element. An element that fails to decode is kept as raw JSON and written back on the next save, so one bad element never wipes the rest. A blob that is not readable at all, or a bookmark envelope with a version other than the supported one, is first copied to `<key>.quarantine.<unix-seconds>` by `StorageQuarantine` (newest 3 kept), before the first overwrite. Loading alone never writes. In history, unreadable elements count toward `maxEntries` and are dropped first; `clearAll` removes them too.

Anchor layout. Saved character offsets are only valid for the text extraction that produced them. `EPUBAnchor.currentLayout` (`Reader/PaginationEngine.swift`) is stored as `anchorLayout` on `HistoryEntry` and `ReadingBookmark`; data without the field decodes as `EPUBAnchor.legacyLayout` (1). Rule: bump `currentLayout` whenever a change alters character offsets, meaning anything touching `ChapterPipeline`, `ChapterText`, or the chapter transforms. M6 bumped `currentLayout` from 1 to 2 when moving the content pipeline to SwiftSoup (hidden instead of removed preface heading and AO3 TOC heading, whitespace exactness, URL resolution). `Locator` restores layout-2 offsets exactly by character offset, falling back to fraction for legacy layout 1 entries. `HistoryManager.record` carries `anchorLayout` forward with the position it describes; only `updatePosition` re-stamps it. The "Collapse empty spacer paragraphs" setting (`SettingsManager.collapseSpacerParagraphs`, key `readerCollapseSpacerParagraphs`, default off) adds a `ql-spacer` class in `ChapterTransforms`; `readerCSS` zeroes the box height. Text nodes are kept, so it does not alter offsets, search or speech text, and needs no `currentLayout` bump.

## 6. Known non-goals (intentional, not gaps)

- No library/catalog view — File > Open / drag-drop / Open Recent / explicit bookmarks only.
- No cross-book full-text search — `SearchBarViewController` is in-book only.
- Publisher CSS is not loaded in the default path (the `<head>` is dropped). The chapter host (flag mode) keeps it (R1); the planned flow surface harvests a small whitelist instead (R21). See `docs/FRAMEWORK.md` C4.
- No per-window/per-book reading mode override — `currentMode` always initializes from the global `SettingsManager.shared.defaultReadingMode`.

## 7. Known architectural gaps and their resolution (historical notes; current plan is `docs/ROADMAP.md`)

- **DRM**: resolved. `EPUBParser` detects real DRM markers and throws `EPUBParseError.drmProtected`; font obfuscation alone is not DRM. Original note: a DRM-protected EPUB fell into the generic `.malformed`/`.opfNotFound` path. Resolution was: detect `META-INF/encryption.xml` in `EPUBParser.parsePackage`, add `EPUBParseError.drmProtected`; the existing in-webview `showError` path already surfaces `errorDescription` with no further plumbing needed.
- **Calibre annotations**: not supported (read or write). Blocked on confirming Calibre's actual on-disk format — Calibre stores highlights/bookmarks in its own library metadata (`metadata.db`/sidecar), not embedded in the EPUB file itself, and a standalone-opened EPUB (Honeycrisp's only input mode — see §6) generally won't carry that sidecar. Needs a real sample before a parser is written. When built: read-only by hard constraint, no write path to the EPUB or any sidecar, enforced in code (not just documented).
- **Quote sharing**: parked in `docs/ROADMAP.md`; no design or code yet.
- **Reading aids**: optional scroll-mode auto-scroll and current-spine native speech are menu-driven. Speech starts from the current selection/location and does not promise continuous multi-spine playback.
- **Scroll-mode page count**: the plan's premise ("no cheap whole-book page count in scroll mode") turned out to already be **false as currently implemented** — `EPUBParser.readerJS`'s `honeycrispPageInfo()` already computes `ceil(scrollHeight/innerHeight)`, and `ReaderViewController.didReceiveScrollPageInfo` already displays it correctly. The only real defect found is a doc comment in `ReaderViewController` that mis-scopes a paginated-mode caveat onto scroll mode too. This item is closer to "verify and fix a comment" than "implement a new calculation."
- **HIG cleanup**: four independent, all confirmed present — `window.title` forced empty in `ReaderViewController.setToolbarTitle` (window title should be set even while hidden from the titlebar, since Window menu/Mission Control/VoiceOver read the model value independent of `titleVisibility`); `ReaderWindowController.setupWindow` sets `isRestorable = false` with state restoration to be implemented (persisting book URL + frame via a security-scoped bookmark, not reading position — see below); 19 `NSLog` debug call sites across `SettingsWindowController`, `ShortcutsSettingsViewController`, `AppDelegate.openSettingsAction`, and one in `ReaderViewController.showThemePopover`, all left over from diagnosing a since-fixed Settings-menu bug, to be deleted; toolbar buttons in `ReaderViewController.makeToolbarButton` accessibility-labeled only via the underlying `NSImage`, to get `setAccessibilityLabel` on the control itself, matching the pattern `SettingsWindowController` already uses correctly elsewhere.
- **Config file**: `SettingsManager` stays `UserDefaults`-only as the source of truth (lower-risk path, per the plan's own recommendation) — no migration off it. Adds export/import: a new `SettingsSnapshot: Codable` aggregating every existing computed property, serialized to `~/Library/Application Support/Honeycrisp/settings.json`, applied back through the existing computed-property setters (not raw `UserDefaults` writes) so existing change-notification and validation side effects still fire.

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
— the same fixed 520×560 constant for General, Appearance, History, and
Shortcuts — so `resolvePreferredPaneSize()` always resolves to the same
size for all five tabs and the animated resize path never actually
resizes anything. This is intentional (see the doc comment on
`SettingsPaneMetrics`: a prior version *did* size per-tab and that read as
unwanted "responsive" resizing), but the plan document was never updated to
reflect the reversal, so it still reads as if per-tab resize is live
behavior. Treat that plan as superseded by this section, not as current behavior. Not changed in code —
this is a deliberate product decision, not a bug, so it's left as-is with
the documentation now caught up to it.

## 10. Settings has exactly one entry point (fixed)

`Sources/App/EPUBReaderApp.swift` used to declare a SwiftUI `Settings` scene
(`SettingsView`, an `NSViewControllerRepresentable` around a *second,
independently-constructed* `SettingsTabViewController`, framed 480×400) in
addition to `AppDelegate`'s manually-built "Settings…" menu item
(`openSettingsAction`, → `SettingsWindowController.shared`). Only the
`SettingsWindowController.shared` path carried the pre-Ventura polish
(`.toolbar` tab style, window-title sync, frame autosave, animated resize
machinery) — the SwiftUI scene was a second, different, unpolished
implementation of the same screen, reachable only if SwiftUI's own
Settings-scene command (normally ⌘, via the App menu) survived
`AppDelegate.setupMenus()` replacing `NSApp.mainMenu` wholesale, which was
never verified either way.

Fixed: `EPUBReaderApp`'s `Settings` scene is now an empty placeholder (kept
only because `Settings` is the one `Scene` kind that doesn't auto-open a
window at launch, so it's the cheapest way to satisfy `some Scene` for an
otherwise 100%-AppDelegate-driven app). `SettingsView`/the duplicate
`SettingsTabViewController` construction is gone. `SettingsWindowController.
shared` via `AppDelegate.openSettingsAction` is now the only Settings
implementation in the app.
