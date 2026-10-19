# Honeycrisp — Architecture

Native macOS EPUB reader. AppKit + WebKit, no SwiftUI beyond the `@main` boot
shim. XcodeGen `project.yml` is the source of truth for the generated Xcode
project. The root Swift package is a secondary build entry point. macOS 13+.

## 1. Project generation

`project.yml` defines the macOS app target, ZIPFoundation dependency, sandbox
entitlements, document type registration, and shared `Honeycrisp` scheme. Run
`xcodegen generate` after changing it. Do not hand-edit the generated
`Honeycrisp.xcodeproj`. Release workflows generate the project before building.

## 2. Process shape

Single-process, multi-window. Each opened book gets its own
`ReaderWindowController` / `ReaderViewController` / `WKWebView`. There is no
document model shared across windows and no library/database — the app's
only persistent state is `UserDefaults` (settings, reader overrides, skin id, key bindings),
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
            ├── TOCSidebarViewController   — NSSplitView sidebar
            └── SearchBarViewController    — in-book search overlay
    SettingsManager (singleton)            — UserDefaults-backed settings and reader overrides
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
| `Reader/ReaderViewController.swift` | The core reading surface: `WKWebView` configuration and message handlers, toolbar (`NSToolbarDelegate`), keyboard/scroll-wheel monitors for paginated mode, TOC sidebar host, search overlay host, cosmetic-vs-structural settings application, position save/restore, title display. |
| `Reader/PaginationEngine.swift` | Drives `PaginationJS` from Swift: column navigation, fraction/offset restore, spine-boundary detection. |
| `Reader/PaginationJS.swift` | JS injected only in paginated mode: column-snap page turns, boundary detection posting back to `PageActionMessageHandler`. |
| `Parsing/EPUBParser.swift` | ZIP extraction (via ZIPFoundation), `container.xml` → OPF → manifest/spine/navigation/landmark parsing, per-chapter HTML extraction/rewriting, whole-spine search indexing, scroll-mode and paginated-mode HTML+CSS builders, and the `readerJS` bridge (search, progress, position, chapter navigation, auto-scroll). |
| `Parsing/TOCParser.swift` | Manifest-declared EPUB3 nav, NCX (EPUB2), and synthesized spine fallback; preserves hierarchy and resolves Start Reading landmarks. |
| `Sidebar/TOCSidebarViewController.swift` | TOC outline view inside the reader's `NSSplitView`. |
| `Sidebar/SearchBarViewController.swift` | Centered in-book search overlay, debounced input, contextual excerpts, and navigable results. Search terms pass to WebKit as JSON string literals. |
| `Sidebar/ThemePopoverViewController.swift` | Toolbar gear-button reader-skin switcher. |
| `History/HistoryManager.swift` | Singleton; `UserDefaults`-backed `[HistoryEntry]` — url, title, opened date, security-scoped bookmark, reading-progress percent, last spine index + character offset. |
| `History/ReadingBookmark.swift` | Codable bookmarks in an independently versioned `UserDefaults` envelope, separate from History. |
| `History/HistoryViewController.swift` | Popover list of recent books (open / remove actions). |
| `Settings/SettingsManager.swift` | Singleton; every user-facing setting, all directly `UserDefaults`-backed (no intermediate model object, no persistence layer). Owns the `Theme` list, font presets, reading-mode default, column count, appearance mode, and posts `.readerCosmeticSettingsChanged` / `.readerStructuralSettingsChanged` / `SettingsManager.settingsChangedNotification` on mutation. |
| `Settings/SettingsWindowController.swift` | Tabbed Settings window (General / Appearance / Advanced-ish "History" tab), all views built imperatively in `loadView()`. |
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
The old Format for AO3 setting is retired and migrates to the default-off
fanfiction preface toggle. Stale sub-flag keys are ignored.

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
3. Back on main: `HistoryManager.record`, TOC sidebar populated, reading mode read from `SettingsManager.shared.defaultReadingMode`.
4. `EPUBParser.buildScrollHTML` or `buildPageHTML` renders the actual HTML document (CSS vars baked in from `ReaderCosmeticSettings.current`), written to a temp file, loaded via `webView.loadFileURL`.
5. `readerJS` (embedded in every rendered document) reports scroll/position/page-info back to Swift via `WKScriptMessageHandler`s registered in `ReaderViewController.loadView()`.

Two independent HTML-generation paths (`buildScrollHTML` for scroll mode, one document per spine item via `buildPageHTML` for paginated mode) share one text-extraction routine (`extractedChapterBody`, driven by a `ChapterRenderOptions` value that search and speech also receive) and one CSS-vars function (`readerVarsCSS`) so the two rendering modes can't drift apart on formatting or theming.

## 5. Settings persistence model

`SettingsManager` is a thin, direct `UserDefaults` wrapper. Reader skin bundles live in `Sources/Skins/Bundled` or Application Support; the selected skin id and global reader overrides live in `UserDefaults`. Existing editable-theme data is converted once to reader overrides and then removed.

## 5b. EPUB rendering, prefaces and skins

EPUB extraction builds one `FrontMatterPlan` per book from OPF metadata and chapter structure. The optional fanfiction-preface setting parses recognized AO3, FicHub, FicLab and WebToEpub front matter into `WorkMeta`, then renders escaped Honeycrisp HTML. Unrecognized or incomplete metadata leaves source content intact. Spine entries remain present; replaced front matter renders as hidden placeholders so TOC, bookmarks and offsets keep their spine indices. Search and speech use the same `ChapterRenderOptions` as visible HTML.

`SourceProfiles` applies narrow, generator-specific fixes after extraction. `.nnwtheme` skins are loaded from the app bundle or Application Support. The loader validates metadata, stylesheet and a restricted template macro set; imported archives reject traversal and symlinks. Book CSS is not loaded. Honeycrisp reader CSS, skin CSS, the optional preface CSS and source-profile CSS are composed in that order, followed by canvas handling. User overrides apply globally.

## 5a. Stored data durability and anchor layout

Storage durability. `HistoryManager` (bare `[HistoryEntry]` array) and `BookmarkManager` (versioned envelope) decode element by element. An element that fails to decode is kept as raw JSON and written back on the next save, so one bad element never wipes the rest. A blob that is not readable at all, or a bookmark envelope with a version other than the supported one, is first copied to `<key>.quarantine.<unix-seconds>` by `StorageQuarantine` (newest 3 kept), before the first overwrite. Loading alone never writes. In history, unreadable elements count toward `maxEntries` and are dropped first; `clearAll` removes them too.

Anchor layout. Saved character offsets are only valid for the text extraction that produced them. `EPUBAnchor.currentLayout` (`Reader/PaginationEngine.swift`) is stored as `anchorLayout` on `HistoryEntry` and `ReadingBookmark`; data without the field decodes as `EPUBAnchor.legacyLayout` (1). Layout 2 saves scroll positions as a spine index plus an offset local to that chapter. Layout-1 entries with spine index 0 use the legacy whole-document restore once; entries with a nonzero spine index use the chapter-local restore. `HistoryManager.record` carries `anchorLayout` forward with the position it describes; `updatePosition` stamps the current layout. Position saves with no text caret return a sentinel and are skipped, preserving the last valid position.

## 6. Known non-goals (intentional, not gaps)

- No library/catalog view — File > Open / drag-drop / Open Recent / explicit bookmarks only.
- No cross-book full-text search — `SearchBarViewController` is in-book only.
- No publisher CSS from the book. User-installed skins, global reader overrides and Honeycrisp-authored preface styling are allowed.
- No per-window/per-book reading mode override — `currentMode` always initializes from the global `SettingsManager.shared.defaultReadingMode`.

## 7. Known architectural gaps and their resolution (see `docs/honeycrisp-settings-window-plan.md` for the Settings-window rebuild plan; other gaps below have no separate plan doc)

- **DRM**: no detection today — a DRM-protected EPUB falls into the generic `.malformed`/`.opfNotFound` path. Resolution: detect `META-INF/encryption.xml` in `EPUBParser.parsePackage`, add `EPUBParseError.drmProtected`; the existing in-webview `showError` path already surfaces `errorDescription` with no further plumbing needed.
- **Calibre annotations**: not supported (read or write). Blocked on confirming Calibre's actual on-disk format — Calibre stores highlights/bookmarks in its own library metadata (`metadata.db`/sidecar), not embedded in the EPUB file itself, and a standalone-opened EPUB (Honeycrisp's only input mode — see §6) generally won't carry that sidecar. Needs a real sample before a parser is written. When built: read-only by hard constraint, no write path to the EPUB or any sidecar, enforced in code (not just documented).
- **Quote sharing**: deferred. Previously listed as a non-goal. No design or code yet; the README lists it under "Planned".
- **Reading aids**: optional scroll-mode auto-scroll and current-spine native speech are menu-driven. Speech starts from the current selection/location and does not promise continuous multi-spine playback.
- **Scroll-mode page count**: the plan's premise ("no cheap whole-book page count in scroll mode") turned out to already be **false as currently implemented** — `EPUBParser.readerJS`'s `honeycrispPageInfo()` already computes `ceil(scrollHeight/innerHeight)`, and `ReaderViewController.didReceiveScrollPageInfo` already displays it correctly. The only real defect found is a doc comment in `ReaderViewController` that mis-scopes a paginated-mode caveat onto scroll mode too. This item is closer to "verify and fix a comment" than "implement a new calculation."
- **HIG cleanup**: four independent, all confirmed present — `window.title` forced empty in `ReaderViewController.setToolbarTitle` (window title should be set even while hidden from the titlebar, since Window menu/Mission Control/VoiceOver read the model value independent of `titleVisibility`); `ReaderWindowController.setupWindow` sets `isRestorable = false` with state restoration to be implemented (persisting book URL + frame via a security-scoped bookmark, not reading position — see below); 19 `NSLog` debug call sites across `SettingsWindowController`, `ShortcutsSettingsViewController`, `AppDelegate.openSettingsAction`, and one in `ReaderViewController.showThemePopover`, all left over from diagnosing a since-fixed Settings-menu bug, to be deleted; toolbar buttons in `ReaderViewController.makeToolbarButton` accessibility-labeled only via the underlying `NSImage`, to get `setAccessibilityLabel` on the control itself, matching the pattern `SettingsWindowController` already uses correctly elsewhere.
- **Config file**: `SettingsManager` stays `UserDefaults`-only as the source of truth (lower-risk path, per the plan's own recommendation) — no migration off it. Adds export/import: a new `SettingsSnapshot: Codable` aggregating every existing computed property, serialized to `~/Library/Application Support/Honeycrisp/settings.json`, applied back through the existing computed-property setters (not raw `UserDefaults` writes) so existing change-notification and validation side effects still fire.

## 8. Decisions carried over from the revision plan

- **Per-window/per-book reading-mode override**: audited, confirmed already absent from the code (`ReaderViewController.currentMode` and `HistoryEntry` both already have no per-book mode field) — closed with no code change, documented here so it stops being re-flagged as missing.
- **Non-goals** (no library view, no cross-book search, no publisher styling) are confirmed intentional and get a README "Non-goals" section; no code changes. Quote sharing was removed from this list: the earlier scoping was outdated, and it is now deferred rather than ruled out.

## 9. Settings window: per-tab resize is wired but inert (by design, undocumented in the plan)

`docs/honeycrisp-settings-window-plan.md` §1.3/§2.2 called the animated
per-tab resize (a `SettingsPaneSizing` protocol, `resolvePreferredPaneSize()`,
`SettingsPanelWindow.setWindowSize`, per-tab size caching) "the main
structural gap" and "the core structural change." All of that machinery is
present in `SettingsWindowController.swift` and is correctly wired to
`SettingsTabViewController.tabView(_:didSelect:)`.

It has no visible effect: every pane's `loadView()` constructs its root
`NSView` with `frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size)`
— the same fixed 520×560 constant for General, Appearance, History, and
Shortcuts — so `resolvePreferredPaneSize()` always resolves to the same
size for all four tabs and the animated resize path never actually
resizes anything. This is intentional (see the doc comment on
`SettingsPaneMetrics`: a prior version *did* size per-tab and that read as
unwanted "responsive" resizing), but the plan document was never updated to
reflect the reversal, so it still reads as if per-tab resize is live
behavior. Treat `docs/honeycrisp-settings-window-plan.md` §1.3/§2.2/§2.4 as
superseded by this section, not as current behavior. Not changed in code —
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
