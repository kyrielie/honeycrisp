// ReaderViewController.swift
// Core reading experience: WebKit rendering, scrolling, toolbar, keyboard nav,
// TOC sidebar, in-book search, reading-progress tracking, dynamic title.
//
// CHANGES vs original:
//  • Toolbar: centered book title plus customizable Search and Contents controls
//  • Title: always shown centered in toolbar (truncated); window.title is also
//    set (setToolbarTitle) so the Window menu/Mission Control/VoiceOver still
//    read the real title even though titleVisibility hides it from the titlebar
//  • TOC: available from a centered popup and the menu bar "Show Table of Contents" (⌘T)
//  • Search: available from the toolbar and menu bar (⌘F); debounced via a 0.3 s Timer
//  • Search highlighting: window.searchText() now returns count AND highlights via
//    CSS mark elements injected by the JS embedded in the HTML template
//  • Settings gear button back in the toolbar (replaces the old paged/scroll
//    toggle button); reading-mode toggle itself moved into Settings' General tab
//  • Page-count display added to the toolbar: "page/pages · chapter/chapters",
//    scoped per spine item (see EPUBParser.honeycrispPageInfo, PaginationEngine.spineDidLoad)
//  • "Format for AO3" rename propagated; EPUBParser receives updated flag name

// swiftlint:disable file_length
import AppKit
import WebKit
import AVFoundation

// swiftlint:disable:next type_body_length
final class ReaderViewController: NSViewController {

    // MARK: - State

    private var webView: ReaderWebView!
    private var loadingIndicator: NSProgressIndicator!
    private var emptyStateView: NSView!
    private var emptyStateHintLabel: NSTextField?
    private var didScheduleEmptyStateHintFade = false

    private var currentPackage: EPUBPackage?
    private var currentEPUBURL: URL?
    /// The active flowing surface implementation (FRAMEWORK contract C5).
    private var surface: FlowingSurface!
    private var extractionWorkDirectories: [URL] = []

    // MARK: - Pagination state (Patch 0007)

    /// Initialized from SettingsManager.shared.defaultReadingMode when a book is
    /// loaded — deliberately not read from or written to HistoryEntry. Every
    /// window opens in whatever the current global default is.
    private(set) var currentMode: ReadingMode = .scroll
    private var paginationEngine: PaginationEngine?
    private var currentSpineIndex: Int = 0
    private var activeScrollSpineIndex: Int = 0
    private var currentFlowOffset: Int = 0
    private var navigationHistory = NavigationHistoryStack<NavigationLocation>()
    private var tocEntries: [TOCEntry] = []
    private var currentChapterTitle: String?
    private var pendingSearchTerm: String?
    private var pendingFragment: String?
    // MARK: - Page count (menu bar display)
    //
    // "Page" is scoped per spine item / chapter for PAGINATED mode only (see
    // PaginationEngine.spineDidLoad's totalCols): paginated mode only ever
    // knows the column count of the currently loaded spine item (see
    // loadSpineItem), since column CSS is baked into one spine item's HTML at
    // a time and a whole-book column count would need a separate offscreen
    // pre-pagination pass across every spine item.
    //
    // Scroll mode does NOT share this limitation: its merged document (see
    // buildScrollHTML) makes scrollHeight the whole book's rendered height,
    // so EPUBParser.honeycrispPageInfo already computes a true whole-book
    // page/totalPages via ceil(scrollHeight/innerHeight) — see
    // didReceiveScrollPageInfo below, which displays that value directly.
    // Displayed as "page/pages · chapter/chapters".
    private var paginatedCurrentColumn: Int = 0
    private var paginatedTotalColumns: Int = 1
    private weak var pageCountLabel: NSTextField?
    private weak var bookmarkButton: NSButton?
    private var bookmarkRefreshGeneration = 0
    private var currentPositionBookmarkID: UUID?
    /// Flips true the first time `viewDidLayout()` runs with the view attached to
    /// a real window — guards the first paginated load against racing the
    /// window's first layout pass, ported from Ambrosia's `isLayoutReady`/
    /// `pendingSpineLoad` pattern (see `loadSpineItem`'s guard below).
    private var isLayoutReady = false
    private var pendingSpineLoad: (index: Int, restorePosition: RestorePosition)?
    private var scrollWheelMonitor: Any?
    /// Accumulated horizontal delta for the swipe currently in progress. Reset on
    /// `.began`, summed on `.changed`, consumed on `.ended`. See
    /// `installScrollWheelMonitorIfNeeded` for why this replaces the old
    /// per-event deadzone check.
    private var swipeAccumulatedDeltaX: CGFloat = 0
    /// Local NSEvent monitor for Left/Right/Page Up/Page Down in paginated mode.
    /// See `installKeyDownMonitor` for why a subclass `keyDown` override alone
    /// isn't sufficient here.
    private var keyDownMonitor: Any?
    private var resizeDebounceTimer: Timer?
    /// Flag mode: the column geometry of the paged chapter on screen, so a layout pass that changed nothing
    /// does not reload it.
    private var lastHostedPagedGeometry: ChapterHostPagedGeometry?
    private var pendingPaginatedRestorePosition: RestorePosition = .start

    /// Set just before switching from paginated mode to scroll mode, so
    /// scrollRestoreBootstrapJS (baked into buildScrollHTML) can seek to the
    /// live paginated position instead of falling back to the possibly-stale
    /// persisted HistoryEntry offset. Consumed and cleared on use.
    private var pendingScrollRestore: (spineIndex: Int, fraction: Double)?
    /// Initial scroll-mode landing point when the user opted to skip an
    /// explicitly identified EPUB cover. Consumed once during first render.
    private var pendingInitialScrollSpineIndex: Int?
    /// Snapshot of the cosmetics actually baked into whatever HTML is
    /// currently loading/loaded (set alongside each buildScrollHTML/
    /// buildPageHTML call). Compared against current settings in
    /// webView(_:didFinish:) so the post-load cosmetic re-sync only fires on
    /// genuine drift — see applyCosmeticCSSUpdate's call site.
    private var lastBuiltCosmetics: ReaderCosmeticSettings?
    private var securityScopedURL: URL?

    private static let readerHTMLFilename = "_ql_reader.html"

    private var fontSizePercent: Int {
        get { SettingsManager.shared.fontSizePercent }
        set { SettingsManager.shared.fontSizePercent = newValue }
    }

    // MARK: - Child VCs

    private var searchBarVC: SearchBarViewController!

    // MARK: - Layout

    private var contentContainer: NSView!
    private var searchOverlay: NSView!
    private var searchBarVisible = false
    private var searchOverlayHeightConstraint: NSLayoutConstraint!
    private var tocPopup: NSPanel?
    private var tocModel: TOCModel?
    private var tocPopupClosedAt: Date?

    // MARK: - Toolbar

    /// Weak refs to toolbar controls that need state updates
    private weak var floatButton: NSButton?
    private var isFloatingWindow = false
    private weak var historyButton: NSButton?
    private weak var searchButton: NSButton?
    private weak var tocButton: NSButton?
    private weak var titleLabel: NSTextField?  // centered title in toolbar
    /// Last values shown in the title and page-count labels. A toolbar item removed
    /// through Customize Toolbar is destroyed, and re-adding it builds a brand-new
    /// label; these let that label start with the current text instead of blank.
    private var toolbarTitleText = ""
    private var toolbarTitleTooltip: String?
    private var pageCountText = ""
    private var appearanceObservation: NSKeyValueObservation?

    /// Debounce timer for search input
    private var searchDebounceTimer: Timer?

    /// Debounce timer for structural settings changes (avoids re-rendering on every
    /// intermediate value while a slider/stepper is being dragged).
    private var structuralSettingsDebounceTimer: Timer?

    /// Periodic position save while a book is open (mirrors Ambrosia's saveTimer) —
    /// belt-and-suspenders alongside the debounced-scroll save, so a reader who
    /// stops scrolling and just sits reading still gets saved periodically.
    private var positionSaveTimer: Timer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var speechQueueGeneration = 0
    private var speechNextSpineIndex: Int?
    private var speechCurrentText: String?
    private var autoScrollSpeed: Double { SettingsManager.shared.autoScrollSpeed }
    private var isAutoScrolling = false
    private var isAdjustingAutoScrollSpeed = false

    // MARK: - View Lifecycle

    // swiftlint:disable:next function_body_length
    override func loadView() {
        // ── WebView ───────────────────────────────────────────────────────────
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false

        let cfg = WKWebViewConfiguration()
        cfg.preferences = prefs
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = .nonPersistent()

        let msgController = WKUserContentController()
        cfg.userContentController = msgController
        // After the controller above is in place: the surface adds its sizing script to it.
        if ChapterHostFlag.isEnabled {
            let host = ChapterHostSurface()
            host.install(into: cfg)
            host.onPositionChange = { [weak self] position, page, pages in
                self?.didReceiveHostPosition(position, chapterPage: page, chapterPages: pages)
            }
            // Paginated mode on the host (M4 pass 7): the pager's edge request and column reports.
            host.onPageAction = { [weak self] forward in self?.navigateSpine(forward: forward) }
            host.onPagerPosition = { [weak self] column, total in
                self?.didReceivePositionUpdate(column: column, totalColumns: total)
            }
            surface = host
        } else {
            let flow = FlowSurface()
            flow.install(into: cfg)
            flow.onProgress = { [weak self] pct in self?.didReceiveProgress(pct) }
            flow.onPosition = { [weak self] resource, offset, fraction in
                self?.didReceiveFlowPosition(resource: resource, offset: offset, fraction: fraction)
            }
            flow.onPageInfo = { [weak self] page, totalPages, spineIndex, spineCount in
                self?.didReceiveScrollPageInfo(
                    page: page, totalPages: totalPages, spineIndex: spineIndex, spineCount: spineCount)
            }
            flow.onPageAction = { [weak self] forward in self?.didReceivePageAction(forward: forward) }
            flow.onPositionUpdate = { [weak self] col, total in
                self?.didReceivePositionUpdate(column: col, totalColumns: total)
            }
            surface = flow
        }

        // Registered before the WKWebView is constructed — Ambrosia's invariant 6
        // requires this ordering. WebKit usually tolerates late registration
        // since content hasn't loaded yet, but that's not guaranteed, so align
        // with the documented-safe order rather than relying on it.
        msgController.add(ProgressMessageHandler(owner: self), name: "progressHandler")
        msgController.add(PositionMessageHandler(owner: self), name: "positionHandler")
        msgController.add(PageActionMessageHandler(owner: self), name: "pageAction")
        msgController.add(PositionUpdateMessageHandler(owner: self), name: "positionUpdate")
        msgController.add(PageInfoMessageHandler(owner: self), name: "pageInfoHandler")

        webView = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 920), configuration: cfg)
        webView.navigationDelegate = self
        speechSynthesizer.delegate = self
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.readerViewController = self

        // The pager runs in the client world for isolated surfaces, or in page context for merged.
        let pagerWorld: WKContentWorld? = surface.pagerContentWorld
        paginationEngine = PaginationEngine(webView: webView, contentWorld: pagerWorld)
        paginationEngine?.spineDidLoad = { [weak self] totalCols in
            guard let self else { return }
            self.paginatedTotalColumns = totalCols
            self.updatePageCountLabel()
        }
        // The restore scroll for .start/.end/.fraction/.characterOffset all
        // happen inline, baked into the HTML by RestorePosition.bootstrapJS
        // (see EPUBParser.buildPageHTML), before first paint — not via a
        // post-load Swift -> JS round trip. positionDidChange is
        // PaginationEngine.applyLayout's readback of the column that inline
        // script already landed on; route it through the same path as
        // message-handler-driven updates so paginatedCurrentColumn is never
        // stale after a spine load.
        paginationEngine?.positionDidChange = { [weak self] column, total in
            self?.didReceivePositionUpdate(column: column, totalColumns: total)
        }
        paginationEngine?.spineNavigationHandler = { [weak self] forward in
            self?.navigateSpine(forward: forward)
        }

        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        // ── Content (webView + search overlay) ───────────────────────────────
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        // enclosingScrollView is nil until now that webView is in the hierarchy.
        // Scrollbar visibility itself is set per-mode by applyScrollbarVisibility,
        // called once currentMode is known (loadEPUB / toggleReadingMode).

        // Search bar overlay (hidden initially)
        searchBarVC = SearchBarViewController()
        searchBarVC.delegate = self
        searchBarVC.onExpandedChange = { [weak self] expanded in
            self?.searchOverlayHeightConstraint.constant = expanded ? 340 : 48
        }
        addChild(searchBarVC)
        searchOverlay = searchBarVC.view
        searchOverlay.translatesAutoresizingMaskIntoConstraints = false
        searchOverlay.isHidden = true
        contentContainer.addSubview(searchOverlay)
        NSLayoutConstraint.activate([
            searchOverlay.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 12),
            searchOverlay.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            searchOverlay.widthAnchor.constraint(equalToConstant: 410),
        ])
        searchOverlayHeightConstraint = searchOverlay.heightAnchor.constraint(equalToConstant: 48)
        searchOverlayHeightConstraint.isActive = true

        contentContainer.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
        ])

        let empty = EPUBDropTargetView()
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.onDrop = { [weak self] url in
            (self?.view.window?.windowController as? ReaderWindowController)?.loadEPUB(at: url)
        }
        let dropSymbolImage = NSImage(
            systemSymbolName: "tray.and.arrow.down",
            accessibilityDescription: "Drop EPUB here"
        )
        let dropSymbol = NSImageView(image: dropSymbolImage ?? NSImage())
        dropSymbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 72, weight: .regular)
        dropSymbol.contentTintColor = .tertiaryLabelColor
        dropSymbol.imageScaling = .scaleProportionallyDown
        dropSymbol.translatesAutoresizingMaskIntoConstraints = false
        dropSymbol.setAccessibilityLabel("Drop EPUB here")
        let hint = NSTextField(labelWithString: "Drag and drop EPUB files")
        hint.textColor = .secondaryLabelColor
        emptyStateHintLabel = hint
        hint.translatesAutoresizingMaskIntoConstraints = false
        empty.addSubview(dropSymbol)
        empty.addSubview(hint)
        contentContainer.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            empty.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            empty.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            dropSymbol.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            dropSymbol.centerYAnchor.constraint(equalTo: empty.centerYAnchor, constant: -32),
            hint.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            hint.topAnchor.constraint(equalTo: dropSymbol.bottomAnchor, constant: 14),
        ])
        emptyStateView = empty
        webView.isHidden = true

        // ── Root ─────────────────────────────────────────────────────────────
        let root = NSVisualEffectView()
        root.material = .contentBackground
        root.blendingMode = .behindWindow
        root.state = .active

        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyCosmeticCSSUpdate),
            name: .readerCosmeticSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleStructuralReload),
            name: .readerStructuralSettingsChanged, object: nil)
        applyDynamicSettings()
        // Every theme now carries both a light and dark ThemeColorSet (see
        // SettingsManager.effectiveColorSet), so a system appearance flip changes
        // the active theme's actual colors, not just the .system special case.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            self?.applyCosmeticCSSUpdate()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
        if currentMode == .paginated {
            installScrollWheelMonitorIfNeeded()
            installKeyDownMonitor()
        }
        fadeOutEmptyStateHintOnce()
    }

    /// Shows the supported-format reminder for a few seconds the first time an empty window
    /// appears, then fades it out. The drop icon stays.
    private func fadeOutEmptyStateHintOnce() {
        guard !didScheduleEmptyStateHintFade, emptyStateView?.isHidden == false,
            let hint = emptyStateHintLabel
        else { return }
        didScheduleEmptyStateHintFade = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak hint] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.2
                hint?.animator().alphaValue = 0
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flushPositionSave()
        removeScrollWheelMonitor()
        removeKeyDownMonitor()
    }

    deinit {
        searchDebounceTimer?.invalidate()
        structuralSettingsDebounceTimer?.invalidate()
        positionSaveTimer?.invalidate()
        resizeDebounceTimer?.invalidate()
        if let monitor = scrollWheelMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyDownMonitor { NSEvent.removeMonitor(monitor) }
        securityScopedURL?.stopAccessingSecurityScopedResource()
        for directory in extractionWorkDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        NotificationCenter.default.removeObserver(self)
        appearanceObservation?.invalidate()
    }

    // MARK: - Security

    private func beginSecurityAccess(for url: URL) {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
    }

    // MARK: - Document Loading

    func loadDocument(at url: URL) {
        loadEPUB(at: url)
    }

    func loadEPUB(at url: URL) {
        emptyStateView?.isHidden = true
        webView?.isHidden = false
        pendingInitialScrollSpineIndex = nil
        navigationHistory.clear()
        currentEPUBURL = url
        showLoading(true)
        beginSecurityAccess(for: url)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var workDir: URL?
            do {
                let applicationSupport = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let createdWorkDir =
                    applicationSupport
                    .appendingPathComponent("Honeycrisp/EPUBReader_\(UUID().uuidString)", isDirectory: true)
                workDir = createdWorkDir
                let pkg = try DocumentImporter.importDocument(at: url, to: createdWorkDir)

                let tocParser = TOCParser()
                let tocEntries = tocParser.parseTOC(for: pkg)

                DispatchQueue.main.async { [weak self] in
                    self?.finishLoading(
                        package: pkg, tocEntries: tocEntries, tocParser: tocParser, workDir: createdWorkDir, url: url)
                }
            } catch {
                if let workDir {
                    try? FileManager.default.removeItem(at: workDir)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.showLoading(false)
                    self?.showError(error)
                }
            }
        }
    }

    /// Main-thread half of `loadEPUB`: publishes the parsed package, works out where to open (saved position, or
    /// past the cover) and renders.
    private func finishLoading(
        package pkg: EPUBPackage, tocEntries: [TOCEntry], tocParser: TOCParser, workDir: URL, url: URL
    ) {
        currentPackage = pkg
        extractionWorkDirectories.append(workDir)
        // Always show title centered in toolbar; never in window chrome
        let title =
            pkg.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : pkg.title
        setToolbarTitle(title, author: pkg.author)
        HistoryManager.shared.record(url: url, title: title)
        self.tocEntries = tocEntries
        self.tocModel = TOCModel(entries: tocEntries, spineURLs: pkg.spineURLs)

        currentMode = SettingsManager.shared.defaultReadingMode
        applyScrollbarVisibility()
        let savedPosition = HistoryManager.shared.savedLocator(for: url)?.flowRestoreTarget
        let start = initialSpineIndex(in: pkg, saved: savedPosition, tocParser: tocParser)
        currentSpineIndex = start.index
        if currentMode == .scroll && start.skippedCover {
            pendingInitialScrollSpineIndex = start.index
        }
        if currentMode == .paginated {
            installScrollWheelMonitorIfNeeded()
            installKeyDownMonitor()
        }
        applyRestoreTarget(savedPosition)

        renderCurrentContent()
        showLoading(false)
        startPositionSaveTimer()
    }

    /// The spine index to open at, and whether that skips the cover. A saved position past the start always wins
    /// over the cover skip.
    private func initialSpineIndex(
        in pkg: EPUBPackage, saved: Locator.FlowRestoreTarget?, tocParser: TOCParser
    ) -> (index: Int, skippedCover: Bool) {
        let savedResource: Int
        let hasMeaningfulSavedPosition: Bool
        switch saved {
        case let .some(.offset(resource, offset)):
            savedResource = resource
            hasMeaningfulSavedPosition = resource > 0 || offset > 0
        case let .some(.fraction(resource, fraction)):
            savedResource = resource
            hasMeaningfulSavedPosition = resource > 0 || fraction > 0
        case .none:
            savedResource = 0
            hasMeaningfulSavedPosition = false
        }
        let coverStartIndex =
            SettingsManager.shared.skipCoverWhenOpening
            ? tocParser.firstSpineIndex(afterCoverIn: pkg)
            : nil
        if !hasMeaningfulSavedPosition, let coverStartIndex {
            return (coverStartIndex, true)
        }
        return (min(savedResource, max(0, pkg.spineURLs.count - 1)), false)
    }

    /// Seeds `pendingPaginatedRestorePosition` from the saved position. An offset of 0 restores to the start in
    /// paged mode and leaves the default in scroll mode.
    private func applyRestoreTarget(_ saved: Locator.FlowRestoreTarget?) {
        guard let saved else { return }
        switch saved {
        case .offset(_, let offset):
            if offset > 0 {
                pendingPaginatedRestorePosition = .characterOffset(offset)
            } else if currentMode == .paginated {
                pendingPaginatedRestorePosition = .start
            }
        case .fraction(_, let fraction):
            pendingPaginatedRestorePosition = .fraction(fraction)
        }
    }

    private func renderCurrentContent() {
        guard let pkg = currentPackage else { return }
        switch currentMode {
        case .scroll:
            renderScrollContent(pkg: pkg)
        case .paginated:
            if let target = surface.targetForPaginatedRestore(fallbackIndex: currentSpineIndex, count: pkg.spineURLs.count) {
                loadSpineItem(index: target.index, restorePosition: target.restore, pkg: pkg)
                return
            }
            loadSpineItem(index: currentSpineIndex, restorePosition: pendingPaginatedRestorePosition, pkg: pkg)
        }
    }

    /// Flag mode (chapter host spike): the current chapter and its neighbours as isolated documents in a
    /// shell page. Nothing is written to `HistoryManager`; the spike has no position, progress or
    /// bookmark support.
    private func renderHostedChapter(_ host: ChapterHostSurface, pkg: EPUBPackage) {
        let cosmetics = ReaderCosmeticSettings.current(from: SettingsManager.shared, language: pkg.language)
        lastBuiltCosmetics = cosmetics
        host.attach(package: pkg, cosmetics: cosmetics)
        let index = min(max(activeScrollSpineIndex, 0), max(0, pkg.spineURLs.count - 1))
        do {
            let restore = host.pendingRestore ?? .start
            host.pendingRestore = nil
            try host.loadWindow(around: index, in: pkg, into: webView, restoring: restore)
        } catch {
            showError(error)
        }
    }

    private func renderFlowContent(_ flow: FlowSurface, pkg: EPUBPackage) {
        do {
            let format = SettingsManager.shared.formatFirstChapter
            let collapseSpacers = SettingsManager.shared.collapseSpacerParagraphs
            let cosmetics = ReaderCosmeticSettings.current(from: SettingsManager.shared, language: pkg.language)
            lastBuiltCosmetics = cosmetics
            let html = try FlowDocumentBuilder.buildDocument(
                package: pkg,
                options: ChapterTransformOptions(
                    formatAO3: format,
                    markSpacers: collapseSpacers
                ),
                cosmetics: cosmetics,
                hideImages: SettingsManager.shared.hideImages
            )
            flow.attach(package: pkg, html: html)
            if let flowURL = flow.documentURL {
                webView.load(URLRequest(url: flowURL))
            }
        } catch {
            showError(error)
        }
    }

    private func renderScrollContent(pkg: EPUBPackage) {
        if surface.managesScrollWindow, let host = surface as? ChapterHostSurface {
            renderHostedChapter(host, pkg: pkg)
            return
        }
        if let flow = surface as? FlowSurface {
            renderFlowContent(flow, pkg: pkg)
        }
    }

    /// JS that seeks scroll mode to wherever it should land, run inline (see
    /// buildScrollHTML) instead of via a post-load evaluateJavaScript call —
    /// that's what avoids painting the top of chapter 1 first and then jumping,
    /// the scroll-mode equivalent of RestorePosition.bootstrapJS in paginated
    /// mode. `pendingScrollRestore` (set just before a paginated -> scroll mode
    /// switch) takes priority over the persisted HistoryEntry offset, since it
    /// carries the live in-session position and the persisted value can be
    /// stale if the debounced position save hasn't flushed yet. Consumed and
    /// cleared on use. Returns "" (a harmless empty inline script) when there's
    /// nothing to restore — first-ever open of a book, which is correctly left
    /// at the top.
    private func scrollRestoreBootstrapJS() -> String {
        if let restore = pendingScrollRestore {
            pendingScrollRestore = nil
            return "window.honeycrispNavigateToChapterFraction(\(restore.spineIndex), \(restore.fraction));"
        }
        if let url = currentEPUBURL,
            let target = HistoryManager.shared.savedLocator(for: url)?.flowRestoreTarget
        {
            switch target {
            case .offset(let resource, let offset) where offset > 0:
                if surface is FlowSurface {
                    return "window.honeycrispNavigateToSectionOffset(\(resource), \(offset));"
                }
                return "window.honeycrispNavigateToOffset(\(offset));"
            case .fraction(let resource, let fraction) where fraction > 0:
                return "window.honeycrispNavigateToChapterFraction(\(resource), \(fraction));"
            case .offset(let resource, _) where resource > 0:
                return "window.navigateToChapter(\(resource));"
            default:
                break
            }
        }
        if let initialSpineIndex = pendingInitialScrollSpineIndex {
            pendingInitialScrollSpineIndex = nil
            return "window.navigateToChapter(\(initialSpineIndex));"
        }
        return ""
    }

    /// Loads a single spine item in paginated mode, with the column layout CSS
    /// baked into the HTML before load (never injected after, to avoid an
    /// unstyled flash before repagination). The restore position is baked in
    /// the same way via `RestorePosition.bootstrapJS` — see
    /// `EPUBParser.buildPageHTML` — so it's already applied by the time the
    /// page first paints; `PaginationEngine.applyLayout` (from
    /// `webView(_:didFinish:)`) just reads back the result.
    private func loadSpineItem(index: Int, restorePosition: RestorePosition, pkg: EPUBPackage) {
        guard index >= 0 && index < pkg.spineURLs.count else { return }
        // Column CSS is computed from webView.bounds; before the window's first
        // real layout pass that bounds is whatever loadView's fixed placeholder
        // frame was, not the real viewport. Defer until viewDidLayout() has fired
        // at least once with the view attached to a real window.
        guard isLayoutReady, view.window != nil else {
            pendingSpineLoad = (index, restorePosition)
            return
        }
        currentSpineIndex = index
        updateCurrentChapter(spineIndex: index)
        if surface.managesPagedChapter, let host = surface as? ChapterHostSurface {
            loadHostedPagedChapter(host, index: index, restorePosition: restorePosition, pkg: pkg)
            return
        }
        pendingPaginatedRestorePosition = restorePosition
        do {
            let parser = EPUBParser()
            let format = SettingsManager.shared.formatFirstChapter
            let removeIndents = SettingsManager.shared.removeParagraphIndents
            let collapseSpacers = SettingsManager.shared.collapseSpacerParagraphs
            let cosmetics = ReaderCosmeticSettings.current(from: SettingsManager.shared, language: pkg.language)
            lastBuiltCosmetics = cosmetics
            let bounds = webView.bounds.isEmpty ? NSRect(x: 0, y: 0, width: 780, height: 920) : webView.bounds
            let html = try parser.buildPageHTML(
                from: pkg, spineIndex: index,
                viewportWidth: bounds.width, viewportHeight: bounds.height,
                colsPerScreen: SettingsManager.shared.colsPerScreen,
                cosmetics: cosmetics,
                restorePosition: restorePosition,
                maxWidth: CGFloat(SettingsManager.shared.maxWidth),
                paddingH: CGFloat(SettingsManager.shared.paddingH),
                paddingV: CGFloat(SettingsManager.shared.paddingV),
                formatFirstChapter: format, removeParagraphIndents: removeIndents,
                collapseSpacerParagraphs: collapseSpacers,
                hideImages: SettingsManager.shared.hideImages
            )
            let indexURL = pkg.rootFolder.appendingPathComponent(Self.readerHTMLFilename)
            try html.write(to: indexURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(indexURL, allowingReadAccessTo: pkg.rootFolder)
        } catch {
            showError(error)
        }
    }

    /// Flag mode (M4 pass 7): one chapter as the top-level document, laid out in columns by the shared pager.
    /// The engine is not ready until `didFinish` has read the layout back, so a key press or a second edge
    /// request during the load is ignored (`navigateSpine`). Nothing is read from or written to history.
    private func loadHostedPagedChapter(
        _ host: ChapterHostSurface, index: Int, restorePosition: RestorePosition, pkg: EPUBPackage
    ) {
        let cosmetics = ReaderCosmeticSettings.current(from: SettingsManager.shared, language: pkg.language)
        lastBuiltCosmetics = cosmetics
        host.attach(package: pkg, cosmetics: cosmetics)
        let geometry = hostedPagedGeometry()
        lastHostedPagedGeometry = geometry
        paginationEngine?.invalidate()
        do {
            try host.loadPaged(
                resource: index, in: pkg, into: webView, geometry: geometry, restore: restorePosition)
        } catch {
            showError(error)
        }
    }

    private func hostedPagedGeometry() -> ChapterHostPagedGeometry {
        ChapterHostPaging.geometry(
            viewport: webView.bounds.size, cols: SettingsManager.shared.colsPerScreen,
            paddingH: SettingsManager.shared.paddingH, paddingV: SettingsManager.shared.paddingV,
            maxWidth: SettingsManager.shared.maxWidth)
    }

    /// Flag mode, paged: reopen the current chapter at the offset of the first text on the page, so a resize or
    /// a structural setting change keeps the text being read on screen (roadmap M4 decision). In memory only.
    private func reloadHostedPagedAtCurrentOffset() {
        guard let engine = paginationEngine, engine.isReady else {
            renderCurrentContent()
            return
        }
        engine.currentOffset { [weak self] offset in
            guard let self else { return }
            if let offset, let host = self.surface as? ChapterHostSurface {
                host.pendingRestore = .position(
                    ChapterHostSurface.Position(resource: self.currentSpineIndex, offset: offset))
            }
            self.renderCurrentContent()
        }
    }

    private func updateCurrentChapter(spineIndex: Int, fragment: String? = nil) {
        currentChapterTitle = tocModel?.title(forSpineIndex: spineIndex)
        tocModel?.setCurrent(TOCLocation(spineIndex: spineIndex, fragment: fragment))
    }

    private func navigate(to spineIndex: Int, offset: Int = 0, chapterLocalOffset: Bool = false) {
        guard let pkg = currentPackage, !pkg.spineURLs.isEmpty else { return }
        let spineIndex = min(max(0, spineIndex), pkg.spineURLs.count - 1)
        let offset = max(0, offset)
        stopAutoScroll()
        stopSpeech()
        if currentMode == .paginated {
            currentSpineIndex = spineIndex
        } else {
            activeScrollSpineIndex = spineIndex
            currentFlowOffset = offset
        }
        updateCurrentChapter(spineIndex: spineIndex)
        if currentMode == .paginated {
            loadSpineItem(index: spineIndex, restorePosition: offset > 0 ? .characterOffset(offset) : .start, pkg: pkg)
        } else if offset > 0 && chapterLocalOffset {
            evaluateInSurfaceWorld(
                "window.honeycrispNavigateToChapterOffset(\(spineIndex), \(offset));")
        } else if offset > 0 {
            evaluateInSurfaceWorld("window.honeycrispNavigateToOffset(\(offset));")
        } else {
            evaluateInSurfaceWorld("window.navigateToChapter(\(spineIndex));")
        }
    }

    // MARK: - Navigation History (Decision R13)

    var canGoBack: Bool { navigationHistory.canGoBack }
    var canGoForward: Bool { navigationHistory.canGoForward }

    func currentNavigationLocation() -> NavigationLocation {
        let resource = currentMode == .scroll ? activeScrollSpineIndex : currentSpineIndex
        let offset = currentMode == .scroll ? currentFlowOffset : paginatedCurrentColumn
        return NavigationLocation(resource: resource, offset: offset)
    }

    func pushCurrentNavigationLocation() {
        guard currentEPUBURL != nil else { return }
        navigationHistory.push(currentNavigationLocation())
    }

    @objc func goBack(_ sender: Any? = nil) {
        let current = currentNavigationLocation()
        guard let target = navigationHistory.goBack(current: current) else { return }
        navigate(to: target.resource, offset: target.offset, chapterLocalOffset: currentMode == .scroll)
    }

    @objc func goForward(_ sender: Any? = nil) {
        let current = currentNavigationLocation()
        guard let target = navigationHistory.goForward(current: current) else { return }
        navigate(to: target.resource, offset: target.offset, chapterLocalOffset: currentMode == .scroll)
    }

    private func evaluateInSurfaceWorld(_ script: String, completion: ((Any?, (any Error)?) -> Void)? = nil) {
        if let world = surface.pagerContentWorld {
            webView.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value): completion?(value, nil)
                case .failure(let error): completion?(nil, error)
                }
            }
        } else {
            webView.evaluateJavaScript(script, completionHandler: completion)
        }
    }

    /// Where the reader is right now: the offset used when a bookmark is created,
    /// plus the character range currently on screen used to decide whether this
    /// page already has one.
    private struct PageLocation {
        let offset: Int
        let visibleRange: ClosedRange<Int>?
    }

    /// Reads the current page location from the web view. The visible range is
    /// what makes "is this page bookmarked" reliable: the offset read at a fixed
    /// screen point rarely equals the offset saved earlier, so equality (or a small
    /// tolerance) cannot recognise a bookmark after navigating back to its page.
    private func readPageLocation(spineIndex: Int, completion: @escaping (PageLocation) -> Void) {
        let isScroll = currentMode == .scroll
        let offsetFunction =
            isScroll
            ? "window.honeycrispCurrentChapterCharacterOffset"
            : "window.honeycrispCurrentCharacterOffset"
        let rangeFunction = "window.honeycrispVisibleCharacterRange"
        let script =
            "(function(){"
            + "var o=\(offsetFunction)?\(offsetFunction)(\(spineIndex)):0;"
            + "var r=\(rangeFunction)?\(rangeFunction)(\(isScroll),\(spineIndex)):null;"
            + "return JSON.stringify({offset:o,range:r});})()"
        evaluateInSurfaceWorld(script) { result, _ in
            var offset = 0
            var visible: ClosedRange<Int>?
            if let text = result as? String,
                let data = text.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                offset = (dict["offset"] as? NSNumber)?.intValue ?? 0
                if let bounds = dict["range"] as? [NSNumber], bounds.count == 2,
                    bounds[0].intValue <= bounds[1].intValue
                {
                    visible = bounds[0].intValue...bounds[1].intValue
                }
            }
            completion(PageLocation(offset: offset, visibleRange: visible))
        }
    }

    /// Bookmarks that belong to the page at `location`. Falls back to the old
    /// proximity test only when the visible range could not be measured.
    private func bookmarks(
        in all: [ReadingBookmark], spineIndex: Int, location: PageLocation
    ) -> [ReadingBookmark] {
        all.filter { bookmark in
            guard bookmark.spineIndex == spineIndex else { return false }
            if let range = location.visibleRange { return range.contains(bookmark.characterOffset) }
            return abs(bookmark.characterOffset - location.offset) <= 64
        }
    }

    private var currentBookmarkSpineIndex: Int {
        currentMode == .scroll ? activeScrollSpineIndex : currentSpineIndex
    }

    /// True when the page on screen already carries a bookmark.
    var isCurrentPositionBookmarked: Bool { currentPositionBookmarkID != nil }

    /// Adds a bookmark for the visible page, or removes the one that is already there.
    func toggleBookmarkAtCurrentPosition() {
        // Surfaces without page scripts (e.g. chapter host) cannot read location and would store offset 0.
        guard surface.supportsBookmarks, let url = currentEPUBURL else { return }
        let spineIndex = currentBookmarkSpineIndex
        readPageLocation(spineIndex: spineIndex) { [weak self] location in
            guard let self else { return }
            let onPage = self.bookmarks(
                in: BookmarkManager.shared.bookmarks(for: url), spineIndex: spineIndex, location: location)
            if onPage.isEmpty {
                let ordinal = spineIndex + 1
                let label = self.currentChapterTitle.map { "\($0) · \(ordinal)" } ?? "Bookmark · \(ordinal)"
                let bookmark = BookmarkManager.shared.add(
                    bookURL: url, label: label, spineIndex: spineIndex,
                    characterOffset: location.offset, chapterTitle: self.currentChapterTitle)
                self.currentPositionBookmarkID = bookmark.id
            } else {
                // Removes every bookmark on this page, including duplicates created
                // before the page-range check existed, so the icon always clears.
                onPage.forEach { BookmarkManager.shared.remove(id: $0.id) }
                self.currentPositionBookmarkID = nil
            }
            self.updateBookmarkButton()
            NSApp.mainMenu?.item(withTitle: "Bookmarks")?.submenu?.update()
        }
    }

    private func refreshBookmarkButton() {
        guard let url = currentEPUBURL else {
            currentPositionBookmarkID = nil
            updateBookmarkButton()
            return
        }
        bookmarkRefreshGeneration += 1
        let generation = bookmarkRefreshGeneration
        let spineIndex = currentBookmarkSpineIndex
        readPageLocation(spineIndex: spineIndex) { [weak self] location in
            guard let self, self.bookmarkRefreshGeneration == generation else { return }
            self.currentPositionBookmarkID =
                self.bookmarks(
                    in: BookmarkManager.shared.bookmarks(for: url), spineIndex: spineIndex, location: location
                ).first?.id
            self.updateBookmarkButton()
        }
    }

    private func updateBookmarkButton() {
        let isBookmarked = currentPositionBookmarkID != nil
        let title = isBookmarked ? "Remove Bookmark" : "Add Bookmark"
        bookmarkButton?.image = NSImage(
            systemSymbolName: isBookmarked ? "bookmark.fill" : "bookmark",
            accessibilityDescription: title
        )
        // Explicit grey/primary tints in both states: leaving the tint unset lets the
        // system apply its accent (blue) when it decides the item is "selected".
        bookmarkButton?.contentTintColor = isBookmarked ? .secondaryLabelColor : .labelColor
        bookmarkButton?.toolTip = title
        bookmarkButton?.setAccessibilityLabel(title)
    }

    func navigate(to bookmark: ReadingBookmark) {
        pushCurrentNavigationLocation()
        navigate(to: bookmark.spineIndex, offset: bookmark.characterOffset, chapterLocalOffset: currentMode == .scroll)
    }

    func startReading() {
        guard let pkg = currentPackage else { return }
        let parser = TOCParser()
        if let node = parser.startReadingNode(in: pkg, toc: tocEntries), let index = node.spineIndex {
            pushCurrentNavigationLocation()
            let fragment = node.url.fragment ?? URLComponents(url: node.url, resolvingAgainstBaseURL: false)?.fragment
            if let fragment, !fragment.isEmpty {
                pendingFragment = fragment
                if currentMode == .scroll {
                    stopAutoScroll()
                    stopSpeech()
                    activeScrollSpineIndex = index
                    updateCurrentChapter(spineIndex: index, fragment: fragment)
                    let targetID = "hc-r\(index)-\(fragment)"
                    if let encoded = EPUBParser.javaScriptStringLiteral(targetID) {
                        evaluateInSurfaceWorld("window.navigateToFragment(\(encoded));")
                        pendingFragment = nil
                    }
                } else {
                    navigate(to: index)
                }
            } else {
                navigate(to: index)
            }
        }
    }

    func goToBeginning() {
        pushCurrentNavigationLocation()
        navigate(to: 0)
    }

    func navigateChapter(forward: Bool) {
        guard let pkg = currentPackage else { return }
        let index = currentMode == .scroll ? activeScrollSpineIndex : currentSpineIndex
        let next = index + (forward ? 1 : -1)
        guard pkg.spineURLs.indices.contains(next) else { return }
        navigate(to: next)
    }

    func goToChapterBeginning() {
        stopAutoScroll()
        let index = currentMode == .scroll ? activeScrollSpineIndex : currentSpineIndex
        if currentMode == .paginated, let pkg = currentPackage {
            loadSpineItem(index: index, restorePosition: .start, pkg: pkg)
        } else {
            evaluateInSurfaceWorld("window.navigateToChapter(\(index));")
        }
    }

    func goToChapterEnd() {
        stopAutoScroll()
        let index = currentMode == .scroll ? activeScrollSpineIndex : currentSpineIndex
        if currentMode == .paginated, let pkg = currentPackage {
            loadSpineItem(index: index, restorePosition: .end, pkg: pkg)
        } else {
            evaluateInSurfaceWorld("window.navigateToChapterEnd(\(index));")
        }
    }

    func setAutoScrollSpeed(_ speed: Double) {
        SettingsManager.shared.autoScrollSpeed = speed
        if isAutoScrolling { startAutoScroll() }
    }

    func startAutoScroll() {
        guard currentMode == .scroll else { return }
        isAutoScrolling = true
        evaluateInSurfaceWorld(
            """
            (function() {
              if (window.honeycrispAutoScrollFrame) cancelAnimationFrame(window.honeycrispAutoScrollFrame);
              var last = 0;
              var speed = \(autoScrollSpeed);
              function step(timestamp) {
                if (!last) last = timestamp;
                var elapsed = Math.min(50, timestamp - last);
                last = timestamp;
                window.scrollBy(0, speed * elapsed / 1000);
                if (window.scrollY + window.innerHeight < document.documentElement.scrollHeight - 1) {
                  window.honeycrispAutoScrollFrame = requestAnimationFrame(step);
                } else {
                  window.honeycrispAutoScrollFrame = null;
                }
              }
              window.honeycrispAutoScrollFrame = requestAnimationFrame(step);
            })();
            """)
    }

    func stopAutoScroll() {
        isAutoScrolling = false
        isAdjustingAutoScrollSpeed = false
        evaluateInSurfaceWorld(
            "if (window.honeycrispAutoScrollFrame) cancelAnimationFrame(window.honeycrispAutoScrollFrame); "
                + "window.honeycrispAutoScrollFrame = null;")
    }

    func speakCurrentLocation() {
        guard currentPackage != nil else { return }
        speechQueueGeneration += 1
        let generation = speechQueueGeneration
        let index = currentMode == .scroll ? activeScrollSpineIndex : currentSpineIndex
        speechNextSpineIndex = index + 1
        evaluateInSurfaceWorld("window.honeycrispCurrentSpeechText(\(index));") { [weak self] result, _ in
            guard let self, self.speechQueueGeneration == generation,
                let text = result as? String, !text.isEmpty
            else { return }
            self.speechSynthesizer.stopSpeaking(at: .immediate)
            self.speechCurrentText = text
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = self.speechRate
            if let id = SettingsManager.shared.speechVoiceIdentifier {
                utterance.voice = AVSpeechSynthesisVoice(identifier: id)
            }
            self.speechSynthesizer.speak(utterance)
        }
    }

    func toggleSpeechPause() {
        if speechSynthesizer.isPaused {
            speechSynthesizer.continueSpeaking()
        } else if speechSynthesizer.isSpeaking {
            speechSynthesizer.pauseSpeaking(at: .immediate)
        } else {
            speakCurrentLocation()
        }
    }

    func adjustSpeechRate(by delta: Float) {
        speechRate = min(
            AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, speechRate + delta))
    }

    func stopSpeech() {
        speechQueueGeneration += 1
        speechNextSpineIndex = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
    func setSpeechVoice(identifier: String?) {
        SettingsManager.shared.speechVoiceIdentifier = identifier
        guard speechSynthesizer.isSpeaking || speechSynthesizer.isPaused,
            let text = speechCurrentText
        else { return }
        let wasPaused = speechSynthesizer.isPaused
        speechQueueGeneration += 1
        let generation = speechQueueGeneration
        speechSynthesizer.stopSpeaking(at: .immediate)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.speechQueueGeneration == generation else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = self.speechRate
            if let identifier, !identifier.isEmpty {
                utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
            }
            self.speechSynthesizer.speak(utterance)
            if wasPaused { self.speechSynthesizer.pauseSpeaking(at: .immediate) }
        }
    }

    func currentBookURL() -> URL? { currentEPUBURL }

    func currentChapterBookmarkLabel() -> String? { currentChapterTitle }

    /// Called from PaginationEngine.spineNavigationHandler when a page turn runs
    /// past the current spine item's last/first column.
    private func navigateSpine(forward: Bool) {
        guard let pkg = currentPackage,
            let target = ChapterHostPaging.handoff(
                from: currentSpineIndex, forward: forward, count: pkg.spineURLs.count)
        else { return }
        // Flag mode: the engine is not ready while a chapter loads, which drops a second request.
        if surface.requiresEngineReadyForSpineNavigation, paginationEngine?.isReady != true { return }
        loadSpineItem(index: target.index, restorePosition: target.restore, pkg: pkg)
    }

    // Paginated-mode position saves are unified with scroll mode's — see
    // flushPositionSave and didReceivePositionUpdate, called after every column
    // navigation, rather than a separate paginated-only scheme.

    private func applyScrollbarVisibility() {
        let scrollView = webView.enclosingScrollView
        switch currentMode {
        case .scroll:
            scrollView?.hasVerticalScroller = true
            scrollView?.hasHorizontalScroller = false
            scrollView?.verticalScrollElasticity = .automatic
            scrollView?.horizontalScrollElasticity = .none
        case .paginated:
            scrollView?.hasVerticalScroller = false
            scrollView?.hasHorizontalScroller = false
            scrollView?.verticalScrollElasticity = .none
            scrollView?.horizontalScrollElasticity = .none
        }
    }

    /// Wired to the View-menu "Paginated Mode" item (⇧⌘P) and the "Paginated Mode"
    /// checkbox in Settings' General tab. Reloads the current content in the new mode at the
    /// equivalent fraction-based position. Mode isn't persisted per-file — nothing
    /// is written back to HistoryEntry here — but it IS written back to
    /// SettingsManager.defaultReadingMode, the global default, so the next book
    /// (and the next window) opens in whatever mode the user last chose. Written
    /// immediately, at the moment the toggle fires, rather than waiting for the
    /// async mode-switch below to complete: the user's intent is decided the
    /// moment they click, and this keeps the new global default consistent with
    /// currentMode even if the window is closed mid-transition.
    @objc func toggleReadingMode(_ sender: Any?) {
        guard let pkg = currentPackage else { return }
        stopAutoScroll()
        let goingTo: ReadingMode = currentMode == .scroll ? .paginated : .scroll
        SettingsManager.shared.defaultReadingMode = goingTo

        if surface.handlesReadingModeToggle, let host = surface as? ChapterHostSurface {
            toggleHostedReadingMode(host, to: goingTo, pkg: pkg)
            return
        }
        if goingTo == .paginated {
            // Scroll mode's own progress fraction (scrollY / scrollHeight) becomes
            // the paginated spine item's restore fraction. Spine index carries over
            // as-is — scroll mode has no notion of "which spine item", so index 0
            // (the merged document's start) is the only thing to hand off; this is
            // an approximation, not lossless, since scroll mode's fraction is over
            // the WHOLE book while paginated mode's fraction is over ONE spine item.
            evaluateInSurfaceWorld("(window.scrollY + window.innerHeight) / document.documentElement.scrollHeight")
            { [weak self] result, _ in
                guard let self else { return }
                self.currentMode = .paginated
                self.applyScrollbarVisibility()
                self.installScrollWheelMonitorIfNeeded()
                self.installKeyDownMonitor()
                let fraction = (result as? Double) ?? 0
                let spineIndex = min(self.activeScrollSpineIndex, max(0, pkg.spineURLs.count - 1))
                self.loadSpineItem(index: spineIndex, restorePosition: .fraction(fraction), pkg: pkg)
            }
        } else {
            let spineIndex = currentSpineIndex
            let finishSwitch: (Double) -> Void = { [weak self] fraction in
                guard let self else { return }
                self.currentMode = .scroll
                self.applyScrollbarVisibility()
                self.removeScrollWheelMonitor()
                self.removeKeyDownMonitor()
                self.pendingScrollRestore = (spineIndex: spineIndex, fraction: fraction)
                self.renderScrollContent(pkg: pkg)
            }
            if paginationEngine?.isReady == true {
                paginationEngine!.currentFraction(completion: finishSwitch)
            } else {
                finishSwitch(0)
            }
        }
    }

    /// Flag mode (M4 pass 7.5): switches between the scroll window and a paged chapter by exact text offset
    /// (decision B2), in memory only; nothing is read from or written to history. Scroll to paged reads the text
    /// on the reference line; paged to scroll reads the first text on the page. A toggle during a chapter load
    /// (engine not ready) reopens that chapter at its start.
    private func toggleHostedReadingMode(_ host: ChapterHostSurface, to goingTo: ReadingMode, pkg: EPUBPackage) {
        let count = pkg.spineURLs.count
        if goingTo == .paginated {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let position = try? await host.firstVisiblePosition(in: self.webView)
                guard self.currentMode == .scroll else { return }
                let target = ChapterHostPaging.toPaged(from: position, activeIndex: self.activeScrollSpineIndex, count: count)
                self.currentSpineIndex = target.index
                host.pendingRestore = target.restore
                self.currentMode = .paginated
                self.applyScrollbarVisibility()
                self.installScrollWheelMonitorIfNeeded()
                self.installKeyDownMonitor()
                self.renderCurrentContent()
            }
            return
        }
        let finish: (Int?) -> Void = { [weak self] offset in
            guard let self, self.currentMode == .paginated else { return }
            let target = ChapterHostPaging.toScroll(index: self.currentSpineIndex, offset: offset, count: count)
            self.activeScrollSpineIndex = target.index
            host.pendingRestore = target.restore
            self.currentMode = .scroll
            self.applyScrollbarVisibility()
            self.removeScrollWheelMonitor()
            self.removeKeyDownMonitor()
            self.renderCurrentContent()
        }
        if let engine = paginationEngine { engine.currentOffset(completion: finish) } else { finish(nil) }
    }

    // MARK: - Toolbar Title

    /// Sets the centered title label in the toolbar (truncated to a reasonable length)
    /// and the window's real title. The titlebar itself still doesn't show text --
    /// ReaderWindowController.setupWindow sets titleVisibility = .hidden -- but
    /// NSWindow.title as a model value is read independently of that by the Window
    /// menu, Mission Control, and VoiceOver, so it needs to be the real title, not
    /// permanently blank.
    private func setToolbarTitle(_ title: String, author: String = "") {
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        view.window?.title = cleanAuthor.isEmpty ? title : "\(title) — \(cleanAuthor)"
        toolbarTitleText = title
        toolbarTitleTooltip = cleanAuthor.isEmpty ? title : "\(title) by \(cleanAuthor)"
        titleLabel?.stringValue = toolbarTitleText
        titleLabel?.toolTip = toolbarTitleTooltip
    }

    // MARK: - Table of Contents

    /// Called from AppDelegate menu action and keyboard shortcut (⌘T).
    @objc func toggleTOC(_ sender: Any?) {
        if tocPopup != nil {
            closeTOCPopup()
            return
        }
        if sender as? NSButton === tocButton,
           let closedAt = tocPopupClosedAt,
           Date().timeIntervalSince(closedAt) < 0.25 {
            tocButton?.state = .off
            tocPopupClosedAt = nil
            return
        }
        guard currentPackage != nil, let model = tocModel else { return }
        guard let window = view.window else { return }

        let popupVC = TOCPopupViewController(model: model)
        let popupHeight = min(520, max(300, window.frame.height - 140))
        popupVC.view.setFrameSize(NSSize(width: 440, height: popupHeight))

        let panel = TOCPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: popupHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentViewController = popupVC
        panel.delegate = self

        let windowFrame = window.frame
        let panelOrigin = NSPoint(
            x: windowFrame.midX - 220,
            y: windowFrame.midY - popupHeight / 2
        )
        panel.setFrameOrigin(panelOrigin)

        popupVC.onSelect = { [weak self] entry in
            self?.closeTOCPopup()
            self?.goToTOCEntry(entry)
        }
        popupVC.onDismiss = { [weak self] in
            self?.closeTOCPopup()
        }

        tocPopup = panel
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        popupVC.prepareForDisplay()
        tocButton?.state = .on
    }

    func closeTOCPopup(restoreFocus: Bool = true) {
        guard let panel = tocPopup else { return }
        tocPopup = nil
        tocPopupClosedAt = Date()
        tocButton?.state = .off
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.close()
        if restoreFocus {
            view.window?.makeKey()
            view.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Search

    /// Called from AppDelegate menu action and keyboard shortcut (⌘F).
    @objc func toggleSearch(_ sender: Any?) {
        toggleSearch(with: nil)
    }

    func toggleSearch(with initialText: String?) {
        if !searchBarVisible {
            searchBarVisible = true
            searchOverlay.isHidden = false
            searchButton?.state = .on
            searchBarVC.beginSearch(with: initialText)
        } else {
            searchBarVisible = false
            searchOverlay.isHidden = true
            searchButton?.state = .off
            searchDebounceTimer?.invalidate()
            evaluateInSurfaceWorld("window.searchText('')")
            searchBarVC.clear()
            view.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Context menu

    /// Wired to the "Search in Browser" context-menu item added by
    /// `ReaderWebView.willOpenMenu`. `NSWorkspace.shared.open(url)` resolves through
    /// default-app resolution — i.e. whatever the user has set as their default
    /// browser, not Safari specifically (which is what WKWebView's own built-in
    /// web-search menu action does internally).
    @objc func searchSelectionInBrowser() {
        evaluateInSurfaceWorld("window.getSelection().toString()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            var comps = URLComponents(string: "https://www.google.com/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = comps.url { NSWorkspace.shared.open(url) }
        }
    }

    @objc func searchSelectionInBook() {
        evaluateInSurfaceWorld("window.getSelection().toString()") { [weak self] result, _ in
            guard let self else { return }
            self.toggleSearch(with: result as? String)
        }
    }

    // MARK: - Display Settings

    /// Full initial apply on load: sets every CSS var. Window appearance is owned by
    /// `SettingsManager.appearanceMode` (applied at launch and on change), not here.
    /// Subsequent changes go through `applyCosmeticCSSUpdate` or
    /// `scheduleStructuralReload` instead, not this.
    @objc func applyDynamicSettings() {
        applyCosmeticCSSUpdate()
    }

    /// JS-only live patch of the `#honeycrisp-vars` `<style>` element's textContent —
    /// no reload, so scroll position and any other DOM state survive a font/theme/
    /// line-height tweak. Builds the replacement CSS with the exact same
    /// `EPUBParser.readerVarsCSS` function buildScrollHTML/buildPageHTML use for the
    /// initial paint, so this can't drift from what a fresh load would produce.
    @objc private func applyCosmeticCSSUpdate() {
        let cosmetics = ReaderCosmeticSettings.current(from: SettingsManager.shared, language: currentPackage?.language)
        lastBuiltCosmetics = cosmetics
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.surface.applyCosmetics(cosmetics, to: self.webView, mode: self.currentMode)
            } catch {
                self.showError(error)
            }
        }
    }

    /// Encodes a Swift string as a safe JS string literal (JSON string syntax is
    /// valid JS string syntax) — for values, like the free-form fontFamily CSS
    /// stack, that may themselves contain quotes.
    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
            let json = String(data: data, encoding: .utf8),
            json.count >= 2
        else { return "''" }
        // json is `["value"]` — strip the surrounding array brackets to get `"value"`
        return String(json.dropFirst().dropLast())
    }

    /// Debounced (~0.15s) full reload for structural settings changes (formatting
    /// flags, pagination layout). A plain Timer, matching the rest of the codebase's
    /// style rather than introducing a dedicated debounce utility for one call site.
    @objc private func scheduleStructuralReload() {
        structuralSettingsDebounceTimer?.invalidate()
        structuralSettingsDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            // Flag mode: the position query below falls back to offset 0 and would overwrite the saved position.
            if let self, self.surface.handlesStructuralReload, let host = self.surface as? ChapterHostSurface {
                if case .paged = host.presentation {
                    self.reloadHostedPagedAtCurrentOffset()
                    return
                }
                // Reopen where the reader is, in memory only: nothing is written to `HistoryManager`.
                Task { @MainActor in
                    if let position = try? await host.firstVisiblePosition(in: self.webView) {
                        host.pendingRestore = .position(position)
                    }
                    self.renderCurrentContent()
                }
                return
            }
            guard let self, let url = self.currentEPUBURL else { self?.renderCurrentContent(); return }
            // Capture current position first so the reload's baked-in restore
            // (scrollRestoreBootstrapJS in scroll mode, pendingPaginatedRestorePosition
            // in paginated mode -- both read from HistoryEntry) lands back where the
            // reader actually was, not wherever they were the last time the book was opened.
            let world = self.surface.pagerContentWorld ?? .page
            self.webView.evaluateJavaScript(
                "window.honeycrispCurrentPosition ? window.honeycrispCurrentPosition() : {resource: 0, offset: 0, fraction: 0}",
                in: nil,
                in: world
            ) { [weak self] result in
                guard let self else { return }
                if case let .success(val) = result,
                    let position = val as? [String: Any],
                    let offset = (position["offset"] as? NSNumber)?.intValue ?? (position["offset"] as? Int),
                    let fraction = (position["fraction"] as? NSNumber)?.doubleValue ?? (position["fraction"] as? Double)
                {
                    let resource = (position["resource"] as? NSNumber)?.intValue ?? (position["resource"] as? Int) ??
                        (self.currentMode == .scroll ? 0 : self.currentSpineIndex)
                    if self.surface is FlowSurface {
                        self.activeScrollSpineIndex = resource
                    }
                    HistoryManager.shared.updatePosition(
                        url: url, spineIndex: resource, characterOffset: offset, fraction: fraction
                    )
                }
                self.renderCurrentContent()
            }
        }
    }

    @objc private func adjustFontSize(_ sender: NSSegmentedControl) {
        let segment = sender.selectedSegment
        if segment == 0 {
            fontSizePercent = max(50, fontSizePercent - 10)
        } else if segment == 1 {
            fontSizePercent = min(300, fontSizePercent + 10)
        }
        DispatchQueue.main.async {
            if segment != -1 { sender.setSelected(false, forSegment: segment) }
        }
        // fontSizePercent's setter already posts .readerCosmeticSettingsChanged,
        // which drives applyCosmeticCSSUpdate — no separate call needed here.
    }

    // MARK: - Progress reporting

    func didReceiveProgress(_ percent: Int) {
        // Flag mode writes no progress (roadmap M4: position and progress persistence is M5).
        guard surface.persistsProgress, let url = currentEPUBURL else { return }
        HistoryManager.shared.updateProgress(url: url, percent: percent)
    }

    // MARK: - Position save/restore

    /// spineIndex is 0 in scroll mode (the whole book is one merged document) and
    /// currentSpineIndex in paginated mode. honeycrispCurrentCharacterOffset (Patch
    /// 0005) is embedded in both buildScrollHTML's and buildPageHTML's readerJS, and
    /// caretRangeFromPoint works the same regardless of which axis is scrolling, so
    /// one save path serves both modes without a separate paginated-only offset
    /// scheme.
    func didReceivePosition(_ offset: Int) {
        guard let url = currentEPUBURL else { return }
        HistoryManager.shared.updatePosition(
            url: url, spineIndex: currentMode == .scroll ? 0 : currentSpineIndex, characterOffset: offset)
    }

    func didReceivePosition(offset: Int, fraction: Double) {
        guard let url = currentEPUBURL else { return }
        HistoryManager.shared.updatePosition(
            url: url,
            spineIndex: currentMode == .scroll ? 0 : currentSpineIndex,
            characterOffset: offset,
            fraction: fraction
        )
    }

    func didReceiveFlowPosition(resource: Int, offset: Int, fraction: Double) {
        guard let url = currentEPUBURL else { return }
        activeScrollSpineIndex = resource
        currentFlowOffset = offset
        if let pkg = currentPackage, pkg.spineURLs.indices.contains(resource) {
            updateCurrentChapter(spineIndex: resource)
        }
        HistoryManager.shared.updatePosition(
            url: url,
            spineIndex: resource,
            characterOffset: offset,
            fraction: fraction
        )
    }

    private func startPositionSaveTimer() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.flushPositionSave()
        }
    }

    /// Best-effort synchronous-as-possible flush: queries the current offset via JS
    /// and saves it immediately, rather than waiting for the next debounced-scroll or
    /// periodic tick. Called when a reader closes the window or navigates away -
    /// without this, quitting mid-page loses however much time elapsed since the
    /// last periodic tick. Also called after every paginated column navigation
    /// (via didReceivePositionUpdate), since PaginationJS's own scroll events don't
    /// drive readerJS's debounced-scroll save path the way scroll mode's do.
    func flushPositionSave() {
        // Surfaces that do not persist positions (e.g. chapter host) skip saving to avoid clobbering history.
        guard surface.persistsPosition, let url = currentEPUBURL else { return }
        let js = "window.honeycrispCurrentPosition ? window.honeycrispCurrentPosition() : {resource: 0, offset: 0, fraction: 0}"
        let world = surface.pagerContentWorld ?? .page
        webView.evaluateJavaScript(js, in: nil, in: world) { [weak self] result in
            guard let self, case let .success(val) = result,
                let position = val as? [String: Any],
                let offset = (position["offset"] as? NSNumber)?.intValue ?? (position["offset"] as? Int),
                let fraction = (position["fraction"] as? NSNumber)?.doubleValue ?? (position["fraction"] as? Double)
            else { return }
            let resource = (position["resource"] as? NSNumber)?.intValue ?? (position["resource"] as? Int) ??
                (self.currentMode == .scroll ? 0 : self.currentSpineIndex)
            if self.surface is FlowSurface {
                self.activeScrollSpineIndex = resource
            }
            HistoryManager.shared.updatePosition(
                url: url,
                spineIndex: resource,
                characterOffset: offset,
                fraction: fraction
            )
        }
    }

    /// PaginationJS's qlNextPage/qlPrevPage post this when a page turn runs past
    /// the current spine item's last/first column.
    func didReceivePageAction(forward: Bool) {
        navigateSpine(forward: forward)
    }

    /// PaginationJS posts this after every column navigation (page turn or
    /// restore). Reuses the same flushPositionSave path scroll mode's debounced
    /// scroll listener drives, rather than a separate paginated-only scheme.
    /// `column`/`totalColumns` (0-based column, total columns in the current
    /// spine item) update the page-count display; nil if the JS payload
    /// couldn't be parsed, in which case the label is simply left as-is.
    func didReceivePositionUpdate(column: Int?, totalColumns: Int?) {
        if let column { paginatedCurrentColumn = column }
        if let totalColumns { paginatedTotalColumns = totalColumns }
        updatePageCountLabel()
        refreshBookmarkButton()
        flushPositionSave()
        reportPaginatedProgress(column: column, totalColumns: totalColumns)
    }

    /// Paginated-mode counterpart to scroll mode's reportProgress() JS. Scroll
    /// mode reports whole-document percent directly from the DOM; paginated
    /// mode only ever sees one spine item at a time, so whole-book percent is
    /// assembled from currentSpineIndex/spineCount (spine/totalspine) and this
    /// item's own column/totalColumns (page/totalpage).
    ///
    /// Deliberately NOT using PaginationJS's qlProgressFraction()/`fraction`
    /// field here: that value is viewport-relative, meant for page-turning
    /// ("is there another screen to page to"), and short-circuits to a flat
    /// 1.0 whenever a whole spine item fits on one screen -- which is most
    /// short chapters. Combined with currentSpineIndex, that pinned percent to
    /// 100% as soon as the last such spine item loaded, independent of actual
    /// read position. column/totalColumns is the raw, un-adjusted page count
    /// within the spine item and doesn't have that failure mode.
    ///
    /// Approximate by design -- spine items aren't equal length, so this
    /// treats each spine item as an equal-sized slice of the book -- matching
    /// the existing tolerance for imprecision when switching reading modes.
    ///
    /// Gated on "Format for AO3" (SettingsManager.formatFirstChapter): AO3's
    /// EPUB export brackets the actual story with a short title-page spine
    /// item and a short end-notes/afterword spine item. Weighing those as
    /// full "1 of N" slices like any real chapter skews percent noticeably on
    /// short works -- leaving the title page for the first real chapter
    /// already counts as finishing a whole spine-slice, and progress is
    /// pinned to 100% for however long the reader is on the end-notes page.
    /// With that setting on, the first and last spine items are excluded
    /// from the slice count entirely: the title page reads as 0% and the
    /// end-notes page reads as 100%, and every real chapter in between is
    /// weighed against the remaining spineCount - 2 items instead of the
    /// full spineCount. Not applied when there are 2 or fewer spine items
    /// (nothing would be left to weigh), and not applied at all with the
    /// setting off, since this bracketing convention is specific to AO3-style
    /// exports and would misread an ordinary EPUB's real first/last chapters.
    private func reportPaginatedProgress(column: Int?, totalColumns: Int?) {
        guard let column, let totalColumns, totalColumns > 0, let pkg = currentPackage else { return }
        let spineCount = max(1, pkg.spineURLs.count)
        let withinSpineFraction = min(1.0, Double(column + 1) / Double(totalColumns))
        let excludeBookends = SettingsManager.shared.formatFirstChapter && spineCount > 2

        let percent: Int
        if excludeBookends && currentSpineIndex == 0 {
            percent = 0
        } else if excludeBookends && currentSpineIndex == spineCount - 1 {
            percent = 100
        } else {
            let effectiveSpineCount = excludeBookends ? spineCount - 2 : spineCount
            let effectiveSpineIndex = excludeBookends ? currentSpineIndex - 1 : currentSpineIndex
            percent = Int(((Double(effectiveSpineIndex) + withinSpineFraction) / Double(effectiveSpineCount)) * 100)
        }
        didReceiveProgress(percent)
    }

    /// Scroll mode's counterpart to the paginated column-based page count —
    /// see EPUBParser.honeycrispPageInfo for how these values are derived.
    /// page/totalPages are whole-book (one "page" = one window-height of
    /// scroll across the merged document); spineIndex/spineCount are
    /// available but not shown here, matching paginated mode's leading
    /// fraction being column-within-chapter rather than book-wide.
    func didReceiveScrollPageInfo(page: Int, totalPages: Int, spineIndex: Int, spineCount: Int) {
        guard currentMode == .scroll else { return }
        activeScrollSpineIndex = min(max(0, spineIndex), max(0, spineCount - 1))
        if let pkg = currentPackage, pkg.spineURLs.indices.contains(activeScrollSpineIndex) {
            updateCurrentChapter(spineIndex: activeScrollSpineIndex)
        }
        setPageCountText("\(page)/\(totalPages)")
        refreshBookmarkButton()
    }

    /// Flag mode (M4): the host reports the chapter on the reference line and the page within it. The label is
    /// per chapter, same format as paginated mode (roadmap R11). Persists nothing.
    func didReceiveHostPosition(_ position: ChapterHostSurface.Position, chapterPage: Int, chapterPages: Int) {
        guard currentMode == .scroll, let pkg = currentPackage, !pkg.spineURLs.isEmpty else { return }
        activeScrollSpineIndex = min(max(0, position.resource), pkg.spineURLs.count - 1)
        updateCurrentChapter(spineIndex: activeScrollSpineIndex)
        setPageCountText("\(chapterPage)/\(chapterPages) \(activeScrollSpineIndex + 1)/\(pkg.spineURLs.count)")
        refreshBookmarkButton()
    }

    /// Paginated-mode counterpart, driven by spineDidLoad/positionUpdate.
    /// Spine index/count come from the currently loaded book's spine, same
    /// values loadSpineItem/navigateSpine already track.
    private func updatePageCountLabel() {
        guard currentMode == .paginated else { return }
        let spineCount = currentPackage?.spineURLs.count ?? 1
        let page = paginatedCurrentColumn + 1
        setPageCountText("\(page)/\(paginatedTotalColumns) \(currentSpineIndex + 1)/\(spineCount)")
    }

    private func setPageCountText(_ text: String) {
        pageCountText = text
        pageCountLabel?.stringValue = text
    }

    // MARK: - Navigation

    /// Scroll-mode-only now: paginated-mode arrow/PageUp/PageDown handling moved
    /// to `installKeyDownMonitor`, which intercepts those keys before WebKit's
    /// own default keyboard-scroll action ever sees them (see that method's doc
    /// comment). This is only still reachable in scroll mode, where there's no
    /// competing native horizontal-scroll handler to race.
    ///
    /// Returns whether the event was actually handled, so callers (ReaderWindow.
    /// keyDown, ReaderWebView.keyDown) can fall back to `super.keyDown(with:)`
    /// for anything not in the switch below, instead of silently swallowing
    /// every other keystroke -- e.g. Tab, Space, or any future system key
    /// AppKit would otherwise handle (including the default "no responder
    /// handled this" beep).
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if SettingsManager.shared.adjustScrollSpeedWhilePaging,
            isAutoScrolling,
            event.keyCode == 126 || event.keyCode == 125
        {
            isAdjustingAutoScrollSpeed = true
            let adjustment = event.keyCode == 126 ? 25.0 : -25.0
            setAutoScrollSpeed(autoScrollSpeed + adjustment)
            return true
        }
        stopAutoScroll()
        switch event.keyCode {
        case 123, 126, 116: scrollByPages(-1)
        case 124, 125, 121: scrollByPages(1)
        case 3 where event.modifierFlags.contains(.command):  // ⌘F
            toggleSearch(nil)
        default: return false
        }
        return true
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard isAdjustingAutoScrollSpeed, event.keyCode == 126 || event.keyCode == 125 else { return false }
        isAdjustingAutoScrollSpeed = false
        return true
    }

    private func scrollByPages(_ pages: Int) {
        stopAutoScroll()
        let js = "window.scrollBy({ top: \(pages) * window.innerHeight, behavior: 'smooth' });"
        evaluateInSurfaceWorld(js)
    }

    // MARK: - Trackpad/scroll-wheel (paginated mode only)
    //
    // WKWebView's internal scroll machinery bypasses a plain scrollWheel(with:)
    // override the same way it bypasses keyDown (see installKeyDownMonitor below)
    // — a local NSEvent monitor is the only reliable interception point.
    //
    // Trackpad input arrives as a stream of `.began`/`.changed`/`.ended` phase
    // events for one physical two-finger swipe, followed by a separate stream of
    // momentum-phase events once the user's fingers lift. The previous
    // implementation fired a page turn on every individual event whose delta
    // exceeded a small deadzone — which fires many times per swipe (once per
    // `.changed` sample) and keeps firing during momentum decay after the
    // fingers are already off the trackpad. This accumulates the swipe distance
    // instead and fires exactly one page turn on `.ended`, and swallows momentum
    // events outright rather than acting on them.
    //
    // Legacy scroll wheels (mice without inertial scrolling) report phase/
    // momentumPhase of `[]` on every event — never `.began`/`.changed`/`.ended` —
    // so they fall through to the `default` case below and keep the previous
    // per-event deadzone behavior, since there's no discrete gesture to
    // accumulate for that input type.

    private func installScrollWheelMonitorIfNeeded() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.currentMode == .paginated, self.view.window?.isKeyWindow == true else { return event }
            if let hitView = self.view.window?.contentView?.hitTest(event.locationInWindow),
                !hitView.isDescendant(of: self.webView)
            {
                return event
            }

            switch event.phase {
            case .began:
                self.swipeAccumulatedDeltaX = 0
                return nil
            case .changed:
                self.swipeAccumulatedDeltaX += event.scrollingDeltaX
                return nil
            case .ended:
                let dx = self.swipeAccumulatedDeltaX
                self.swipeAccumulatedDeltaX = 0
                // Threshold is on total swipe distance, not per-event sample.
                if abs(dx) > 30 {
                    self.paginationEngine?.handleKeyDown(dx > 0 ? .backward : .forward)
                }
                return nil
            default:
                guard event.momentumPhase.isEmpty else { return nil }  // swallow momentum
                // No phase at all: legacy mouse wheel. Keep the old per-event
                // deadzone behavior since there's no .began/.changed/.ended
                // gesture to accumulate here.
                let delta =
                    abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX : event.scrollingDeltaY
                guard abs(delta) > 2 else { return nil }
                self.paginationEngine?.handleKeyDown(delta > 0 ? .backward : .forward)
                return nil
            }
        }
    }

    private func removeScrollWheelMonitor() {
        if let monitor = scrollWheelMonitor { NSEvent.removeMonitor(monitor) }
        scrollWheelMonitor = nil
        swipeAccumulatedDeltaX = 0
    }

    // MARK: - Keyboard navigation monitor (paginated mode only)
    //
    // WebKit applies its own default keyboard-scroll action for Left/Right
    // directly in the web content process whenever :root has overflow-x: scroll
    // (required for column layout) — independent of the AppKit responder chain.
    // That native handling runs regardless of what ReaderWebView.keyDown (a
    // plain subclass override) does, producing a visible horizontal nudge on top
    // of — or instead of — the intended column snap. A local NSEvent monitor
    // sees the key event before it is ever dispatched to the web view, so
    // returning nil here reliably prevents WebKit's native handling from running
    // at all. ReaderWebView.keyDown still handles vertical paging in scroll mode
    // (no competing native horizontal-scroll handler there); this monitor only
    // acts in paginated mode.

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.currentMode == .paginated, event.window === self.view.window else { return event }
            guard let responder = self.view.window?.firstResponder as? NSView,
                responder.isDescendant(of: self.view)
            else { return event }
            if responder is NSTextView || responder is NSTextField { return event }

            switch event.keyCode {
            case 123, 126, 116:  // ← ↑ Page Up
                guard !event.isARepeat else { return nil }
                self.paginationEngine?.handleKeyDown(.backward)
                return nil
            case 124, 125, 121:  // → ↓ Page Down
                guard !event.isARepeat else { return nil }
                self.paginationEngine?.handleKeyDown(.forward)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyDownMonitor() {
        if let monitor = keyDownMonitor { NSEvent.removeMonitor(monitor) }
        keyDownMonitor = nil
    }

    // MARK: - Resize (paginated mode only)
    //
    // Column CSS is baked into the HTML, so a resize requires a full spine reload
    // with updated viewport geometry, not just re-running JS.

    override func viewDidLayout() {
        super.viewDidLayout()

        // First real layout pass: flip isLayoutReady and replay any load that was
        // deferred by loadSpineItem's guard while the window had no real geometry
        // yet. Return without also scheduling a resize-reload in this same pass —
        // this is the initial layout the deferred load was waiting for, not a
        // resize.
        if !isLayoutReady, view.window != nil {
            isLayoutReady = true
            if let pending = pendingSpineLoad, let pkg = currentPackage {
                pendingSpineLoad = nil
                loadSpineItem(index: pending.index, restorePosition: pending.restorePosition, pkg: pkg)
            }
            return
        }

        guard currentMode == .paginated, currentPackage != nil else { return }
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, let pkg = self.currentPackage else { return }
            // Don't clobber a still-pending restore with .fraction(0) if this
            // layout pass fired before PaginationEngine.applyLayout finished its
            // own setup (isReady flips true only once that completes).
            guard self.paginationEngine?.isReady == true else { return }
            if self.surface.handlesPaginatedResize {
                // Flag mode: only a changed geometry reloads, and it restores the exact offset.
                if self.hostedPagedGeometry() != self.lastHostedPagedGeometry { self.reloadHostedPagedAtCurrentOffset() }
                return
            }
            self.paginationEngine?.currentFraction { fraction in
                self.loadSpineItem(index: self.currentSpineIndex, restorePosition: .fraction(fraction), pkg: pkg)
            }
        }
    }

    // MARK: - Toolbar updates

    func updateFloatButton(isFloating: Bool) {
        isFloatingWindow = isFloating
        floatButton?.image = NSImage(
            systemSymbolName: isFloating ? "pin.fill" : "pin",
            accessibilityDescription: "Float on top"
        )
        floatButton?.state = .off
        floatButton?.contentTintColor = isFloating ? .secondaryLabelColor : .labelColor
        floatButton?.toolTip = isFloating ? "Stop floating on top" : "Float on top"
    }

    // MARK: - Helpers

    private func showLoading(_ loading: Bool) {
        loadingIndicator.isHidden = !loading
        if loading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }

    private func showError(_ error: Error) {
        let html = """
            <!doctype html><html>
            <head><style>
            body { font: -apple-system-body; padding: 48px 40px; max-width: 500px; margin: auto; }
            pre { opacity: 0.6; white-space: pre-wrap; font-size: 13px; }
            </style></head>
            <body><h3>⚠ Could not open EPUB</h3><pre>\(error.localizedDescription)</pre></body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Toolbar Actions

    @objc func showHistory(_ sender: NSButton) {
        let historyVC = HistoryViewController { [weak self] url in
            self?.loadEPUB(at: url)
            self?.presentedViewControllers?.forEach { $0.dismiss(self) }
        }
        historyVC.reload()

        let popover = NSPopover()
        popover.contentViewController = historyVC
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc func openFile(_ sender: Any?) {
        (view.window?.windowController as? ReaderWindowController)?.showOpenPanel()
    }

    @objc private func bookmarkAction(_ sender: Any?) {
        toggleBookmarkAtCurrentPosition()
    }

    /// Toolbar gear button — shows a quick Apple-Books-style theme popover
    /// rather than opening the full Settings window. The full Settings window
    /// (SettingsWindowController) is now reachable only from the App menu's
    /// "Settings…" (⌘,) item.
    ///
    /// This method is deliberately NOT named `openSettingsAction:`. AppDelegate
    /// already implements a method with that exact selector, and the App menu's
    /// "Settings…" item has a nil target, so it resolves its action by walking
    /// the responder chain by selector name starting at the key window's first
    /// responder. ReaderViewController sits in that chain (it's the reader
    /// window's contentViewController, and a reader window is key almost
    /// always), so a same-named method here would intercept the menu item
    /// before the chain ever reached AppDelegate -- which is exactly why
    /// "Ambrosia > Settings…" was a no-op even after the toolbar button itself
    /// was fixed.
    @objc private func showThemePopover(_ sender: NSButton) {
        let themeVC = ThemePopoverViewController()

        let popover = NSPopover()
        popover.contentViewController = themeVC
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func floatAction(_ sender: Any?) {
        (view.window?.windowController as? ReaderWindowController)?.toggleFloat(sender)
    }
}

// MARK: - Table of Contents Navigation

extension ReaderViewController {

    func goToTOCEntry(_ entry: TOCEntry) {
        guard let pkg = currentPackage else { return }
        let target = entry.absoluteURL.standardizedFileURL
        guard let idx = pkg.spineURLs.firstIndex(where: { $0.standardizedFileURL.path == target.path }) else {
            NSSound.beep()
            return
        }
        pushCurrentNavigationLocation()
        let fragment = entry.absoluteURL.fragment ?? URLComponents(url: target, resolvingAgainstBaseURL: false)?.fragment
        updateCurrentChapter(spineIndex: idx, fragment: fragment)
        if let fragment, !fragment.isEmpty {
            if currentMode == .paginated && currentSpineIndex != idx {
                pendingFragment = fragment
                loadSpineItem(index: idx, restorePosition: .start, pkg: pkg)
            } else if currentMode == .paginated {
                if let encoded = EPUBParser.javaScriptStringLiteral(fragment) {
                    evaluateInSurfaceWorld("window.navigateToFragment(\(encoded));")
                }
            } else {
                stopAutoScroll()
                stopSpeech()
                activeScrollSpineIndex = idx
                let namespacedTarget = "hc-r\(idx)-\(fragment)"
                if let encoded = EPUBParser.javaScriptStringLiteral(namespacedTarget) {
                    evaluateInSurfaceWorld("window.navigateToFragment(\(encoded));")
                }
            }
        } else {
            navigate(to: idx)
        }
    }
}

// MARK: - SearchBarDelegate

extension ReaderViewController: SearchBarDelegate {

    /// Debounce search so JS evaluation only fires 0.3 s after the user stops typing.
    func searchBar(_ bar: SearchBarViewController, didSearch term: String) {
        searchDebounceTimer?.invalidate()
        pendingSearchTerm = term
        guard !term.isEmpty else {
            evaluateInSurfaceWorld("window.searchText('');")
            bar.showResults([], chapterTitles: [:])
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self, weak bar] _ in
            guard let self, let bar, let package = self.currentPackage else { return }
            let titleMap = Dictionary(
                uniqueKeysWithValues: package.spineURLs.indices.map { index in
                    let targetPath = package.spineURLs[index].standardizedFileURL.path
                    let chapter =
                        self.flattenTOCEntries(self.tocEntries)
                        .first(where: { $0.absoluteURL.standardizedFileURL.path == targetPath })?.title
                        ?? "Chapter \(index + 1)"
                    return (index, chapter)
                })
            DispatchQueue.global(qos: .userInitiated).async {
                let options = ChapterTransformOptions.current(from: SettingsManager.shared)
                let results = EPUBParser().searchResults(for: term, in: package, options: options)
                DispatchQueue.main.async { [weak self, weak bar] in
                    guard let self, let bar, self.pendingSearchTerm == term else { return }
                    bar.showResults(results, chapterTitles: titleMap)
                    if !results.isEmpty { bar.selectResult(at: 0) }
                    guard let encoded = EPUBParser.javaScriptStringLiteral(term) else { return }
                    self.evaluateInSurfaceWorld("window.searchText(\(encoded));")
                }
            }
        }
    }

    private func flattenTOCEntries(_ entries: [TOCEntry]) -> [TOCEntry] {
        entries.flatMap { [$0] + flattenTOCEntries($0.children) }
    }

    func searchBar(_ bar: SearchBarViewController, didSelect result: BookSearchResult) {
        pushCurrentNavigationLocation()
        navigate(to: result.spineIndex, offset: result.characterOffset, chapterLocalOffset: currentMode == .scroll)
        if currentMode == .paginated { pendingSearchTerm = searchBarVC.searchFieldValue }
    }

    func searchBarDidRequestNext(_ bar: SearchBarViewController) {
        bar.stepResult(by: 1)
    }

    func searchBarDidRequestPrevious(_ bar: SearchBarViewController) {
        bar.stepResult(by: -1)
    }

    func searchBarDidDismiss(_ bar: SearchBarViewController) {
        searchBarVisible = false
        searchOverlay.isHidden = true
        searchButton?.state = .off
        searchDebounceTimer?.invalidate()
        evaluateInSurfaceWorld("window.searchText('')")
        pendingSearchTerm = nil
        bar.clear()
        view.window?.makeFirstResponder(webView)
    }
}

extension ReaderViewController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === tocPopup else { return }
        closeTOCPopup(restoreFocus: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === tocPopup else { return }
        closeTOCPopup(restoreFocus: false)
    }
}

extension ReaderViewController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let nextIndex = speechNextSpineIndex, let package = currentPackage,
            package.spineURLs.indices.contains(nextIndex)
        else {
            speechNextSpineIndex = nil
            return
        }
        let generation = speechQueueGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parser = EPUBParser()
            let options = ChapterTransformOptions.current(from: SettingsManager.shared)
            var candidate = nextIndex
            var text: String?
            while package.spineURLs.indices.contains(candidate), text == nil {
                text = parser.speechText(in: package, at: candidate, options: options)
                if text == nil { candidate += 1 }
            }
            let followingIndex = candidate + 1
            DispatchQueue.main.async {
                guard let self, self.speechQueueGeneration == generation else { return }
                guard let text else {
                    self.speechNextSpineIndex = nil
                    return
                }
                self.speechNextSpineIndex = followingIndex
                self.speechCurrentText = text
                let next = AVSpeechUtterance(string: text)
                next.rate = self.speechRate
                if let id = SettingsManager.shared.speechVoiceIdentifier {
                    next.voice = AVSpeechSynthesisVoice(identifier: id)
                }
                synthesizer.speak(next)
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension ReaderViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if action.navigationType == .linkActivated,
            let url = action.request.url,
            url.scheme == "https" || url.scheme == "http"
        {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if action.navigationType == .linkActivated {
            pushCurrentNavigationLocation()
        }
        if !surface.allowsNavigation(action: action, currentURL: webView.url) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if surface.didFinishNavigation(
            in: webView, paginationEngine: paginationEngine, colsPerScreen: SettingsManager.shared.colsPerScreen
        ) {
            refreshBookmarkButton()
            return
        }
        // The initial HTML already bakes real settings in via ReaderCosmeticSettings
        // (see buildScrollHTML/buildPageHTML). Re-applying unconditionally here was
        // itself a source of a visible flash on every load -- even when values match,
        // rewriting #honeycrisp-vars forces a second style recalc right after first
        // paint, and when a setting genuinely changed in the (synchronous build,
        // async load) window it produced a color flip after the correct colors had
        // already painted. Only re-sync if lastBuiltCosmetics actually disagrees with
        // the current settings snapshot.
        let currentCosmetics = ReaderCosmeticSettings.current(
            from: SettingsManager.shared, language: currentPackage?.language
        )
        if lastBuiltCosmetics != currentCosmetics {
            applyCosmeticCSSUpdate()
        }
        switch currentMode {
        case .scroll:
            if surface is FlowSurface {
                let restoreJS = scrollRestoreBootstrapJS()
                if !restoreJS.isEmpty {
                    evaluateInSurfaceWorld(restoreJS)
                }
            }
        case .paginated:
            paginationEngine?.setColsPerScreen(SettingsManager.shared.colsPerScreen)
            paginationEngine?.applyLayout(restorePosition: pendingPaginatedRestorePosition)
        }
        if let term = pendingSearchTerm, let encoded = EPUBParser.javaScriptStringLiteral(term) {
            evaluateInSurfaceWorld("window.searchText(\(encoded));")
        }
        if let fragment = pendingFragment, let encoded = EPUBParser.javaScriptStringLiteral(fragment) {
            pendingFragment = nil
            evaluateInSurfaceWorld("window.navigateToFragment(\(encoded));")
        }
        refreshBookmarkButton()
    }
}

// MARK: - NSToolbarDelegate
//
// Toolbar items are natively customizable; users can add/remove them from the
// toolbar context menu and restore the default set from Customize Toolbar.
//
// Search and Contents are direct controls; mode and reading preferences live
// in Settings.

extension ReaderViewController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Reading-first default: navigation on the left, title centered, the controls
        // used mid-read on the right. Open (Cmd-O), History, Float and Page Count stay
        // available through Customize Toolbar. Existing windows keep their saved layout
        // because the toolbar identifier carries a version (see ReaderWindowController).
        [
            .toc, .flexibleSpace, .titleLabel, .flexibleSpace, .search, .bookmark, .fontSize, .themePopover,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .openFile, .titleLabel, .search, .toc, .pageCount, .fontSize, .themePopover, .history, .floatToggle,
            .bookmark, .space, .flexibleSpace,
        ]
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {

        case .openFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = makeToolbarButton(symbol: "folder", tooltip: "Open EPUB…", action: #selector(openFile(_:)))
            item.label = "Open"
            return item

        case .search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = makeToolbarButton(
                symbol: "magnifyingglass", tooltip: "Search in Book", action: #selector(toggleSearch(_:)))
            button.setButtonType(.toggle)
            searchButton = button
            item.view = button
            item.label = "Search"
            return item

        case .toc:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = makeToolbarButton(
                symbol: "list.bullet", tooltip: "Table of Contents", action: #selector(toggleTOC(_:)))
            button.setButtonType(.toggle)
            tocButton = button
            item.view = button
            item.label = "Contents"
            return item

        case .titleLabel:
            // A non-interactive, centered, truncating label showing the book title.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            // Fix a reasonable width so it truncates gracefully
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            label.stringValue = toolbarTitleText
            label.toolTip = toolbarTitleTooltip
            titleLabel = label
            item.view = label
            // Non-empty so the item is visible and draggable in Customize Toolbar.
            item.label = "Title"
            item.paletteLabel = "Title"
            return item

        case .fontSize:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let seg = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "textformat.size.smaller", accessibilityDescription: "Decrease Font")!,
                    NSImage(systemSymbolName: "textformat.size.larger", accessibilityDescription: "Increase Font")!,
                ],
                trackingMode: .momentary, target: self, action: #selector(adjustFontSize(_:))
            )
            seg.setAccessibilityLabel("Font Size")
            // Per-segment tooltips so VoiceOver / hover can distinguish the
            // two icon-only segments individually, not just the control's
            // overall label -- same reasoning as makeToolbarButton's
            // setAccessibilityLabel below. setToolTip(forSegment:), not
            // setLabel(forSegment:), since these segments are icon-only and
            // setLabel would render visible text alongside the icons.
            seg.setToolTip("Decrease Font Size", forSegment: 0)
            seg.setToolTip("Increase Font Size", forSegment: 1)
            item.view = seg
            item.label = "Font Size"
            return item

        case .history:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = makeToolbarButton(symbol: "clock", tooltip: "Recent files", action: #selector(showHistory(_:)))
            historyButton = btn
            item.view = btn
            item.label = "History"
            return item

        case .pageCount:
            // Non-interactive label, same pattern as .titleLabel: "3 of 12 · Ch 2 of 20".
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            label.stringValue = pageCountText
            pageCountLabel = label
            item.view = label
            // Non-empty so the item is visible and draggable in Customize Toolbar;
            // an empty label made it a blank, effectively unfindable palette entry.
            item.label = "Page Count"
            item.paletteLabel = "Page Count"
            // First to collapse into the overflow menu when the window gets narrow.
            item.visibilityPriority = .low
            return item

        case .themePopover:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = makeToolbarButton(
                symbol: "circle.lefthalf.filled", tooltip: "Theme…", action: #selector(showThemePopover(_:)))
            item.view = btn
            item.label = "Theme"
            return item

        case .floatToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = makeToolbarButton(symbol: "pin", tooltip: "Float on top", action: #selector(floatAction(_:)))
            floatButton = btn
            updateFloatButton(isFloating: isFloatingWindow)
            item.view = btn
            item.label = "Float"
            return item

        case .bookmark:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = makeToolbarButton(
                symbol: "bookmark", tooltip: "Add Bookmark", action: #selector(bookmarkAction(_:)))
            bookmarkButton = button
            item.view = button
            item.label = "Bookmark"
            updateBookmarkButton()
            refreshBookmarkButton()
            return item

        default: return nil
        }
    }

    private func makeToolbarButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!,
            target: self, action: action
        )
        btn.bezelStyle = .texturedRounded
        btn.toolTip = tooltip
        btn.isBordered = false
        btn.setButtonType(.momentaryLight)
        // Toolbar buttons never take keyboard focus. Without this the first button
        // (Open) can be drawn highlighted after the web view is dragged in, and the
        // system may tint a focused item with the accent color.
        btn.refusesFirstResponder = true
        btn.focusRingType = .none
        btn.showsBorderOnlyWhileMouseInside = false
        btn.contentTintColor = .labelColor
        // VoiceOver reads the control's own accessibility label over the
        // underlying NSImage's accessibilityDescription when both exist, and
        // an NSButton doesn't reliably inherit the image's description as its
        // own label -- set it explicitly, matching the pattern
        // SettingsWindowController already uses for its own controls.
        btn.setAccessibilityLabel(tooltip)
        return btn
    }
}

// MARK: - WKScriptMessageHandler (progress)

private class ProgressMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderViewController?
    init(owner: ReaderViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let pct = message.body as? Int else { return }
        owner?.didReceiveProgress(pct)
    }
}

private class PositionMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderViewController?
    init(owner: ReaderViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let position = message.body as? [String: Any],
            let offset = position["offset"] as? Int,
            let fraction = position["fraction"] as? Double
        {
            owner?.didReceivePosition(offset: offset, fraction: fraction)
            return
        }
        guard let offset = message.body as? Int else { return }
        owner?.didReceivePosition(offset)
    }
}

/// Receives `{ action: 'nextSpineItem' | 'prevSpineItem' }` from PaginationJS's
/// qlNextPage/qlPrevPage when a page turn runs past the current spine item's
/// last/first column.
private class PageActionMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderViewController?
    init(owner: ReaderViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // PaginationJS posts JSON.stringify({...}) — a String, not a dictionary.
        guard let str = message.body as? String,
            let data = str.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = dict["action"] as? String
        else { return }
        owner?.didReceivePageAction(forward: action == "nextSpineItem")
    }
}

/// Receives `{ fraction, column, totalColumns }` from PaginationJS's
/// _postPositionUpdate, posted after every column navigation (page turn or
/// restore). Triggers a position save via the same flushPositionSave path scroll
/// mode's debounced scroll listener drives, and updates the page-count display.
private class PositionUpdateMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderViewController?
    init(owner: ReaderViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let str = message.body as? String,
            let data = str.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            owner?.didReceivePositionUpdate(column: nil, totalColumns: nil)
            return
        }
        let column = (dict["column"] as? NSNumber)?.intValue
        let total = (dict["totalColumns"] as? NSNumber)?.intValue
        owner?.didReceivePositionUpdate(column: column, totalColumns: total)
    }
}

/// Receives `{ page, totalPages, spineIndex, spineCount }` from
/// EPUBParser's honeycrispPageInfo() (scroll mode only). Updates the
/// page-count toolbar label.
private class PageInfoMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderViewController?
    init(owner: ReaderViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let str = message.body as? String,
            let data = str.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let page = (dict["page"] as? NSNumber)?.intValue,
            let totalPages = (dict["totalPages"] as? NSNumber)?.intValue,
            let spineIndex = (dict["spineIndex"] as? NSNumber)?.intValue,
            let spineCount = (dict["spineCount"] as? NSNumber)?.intValue
        else { return }
        owner?.didReceiveScrollPageInfo(
            page: page, totalPages: totalPages, spineIndex: spineIndex, spineCount: spineCount)
    }
}

// MARK: - ReaderWebView

final class ReaderWebView: WKWebView {
    weak var readerViewController: ReaderViewController?
    override func keyDown(with event: NSEvent) {
        let navigationKeys: Set<UInt16> = [123, 124, 125, 126, 116, 121]
        if navigationKeys.contains(event.keyCode), let vc = readerViewController {
            vc.handleKeyDown(event)
        } else if event.keyCode == 3 && event.modifierFlags.contains(.command) {
            // ⌘F — toggle search
            readerViewController?.toggleSearch(nil)
        } else {
            super.keyDown(with: event)
        }
    }
    override var acceptsFirstResponder: Bool { true }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // WKWebView tags its built-in items with a stable NSMenuItem.identifier
        // (e.g. "WKMenuItemIdentifierShareMenu"). These strings are undocumented
        // but have shipped unchanged across macOS releases and are commonly relied
        // on for exactly this. Reading NSMenuItem.identifier itself is ordinary
        // public AppKit API; no private header import needed.
        let idsToRemove: Set<String> = [
            "WKMenuItemIdentifierShareMenu",
            "WKMenuItemIdentifierSearchWeb",
        ]
        // "Copy Link with Highlight" doesn't have a confirmed stable identifier;
        // match by title instead. Honeycrisp has no localization (no .lproj
        // folders in the project), so an English title match is safe here — flag
        // this if Honeycrisp is ever localized.
        let titlesToRemove: Set<String> = ["Copy Link with Highlight"]

        menu.items.removeAll { item in
            if let id = item.identifier?.rawValue, idsToRemove.contains(id) { return true }
            if titlesToRemove.contains(item.title) { return true }
            return false
        }

        // Replace the native "Search With Google" (opens via Safari specifically,
        // not the user's default browser — a known WKWebView quirk) with a version
        // that goes through NSWorkspace, which always respects the user's actual
        // default browser.
        let searchItem = NSMenuItem(
            title: "Search in Book",
            action: #selector(ReaderViewController.searchSelectionInBook),
            keyEquivalent: ""
        )
        searchItem.target = readerViewController
        menu.insertItem(searchItem, at: 0)

        let browserSearchItem = NSMenuItem(
            title: "Search in Browser",
            action: #selector(ReaderViewController.searchSelectionInBrowser),
            keyEquivalent: ""
        )
        browserSearchItem.target = readerViewController
        menu.insertItem(browserSearchItem, at: 1)

        super.willOpenMenu(menu, with: event)
    }
}

// MARK: - Toolbar identifier extensions

extension NSToolbarItem.Identifier {
    static let openFile = NSToolbarItem.Identifier("openFile")
    static let search = NSToolbarItem.Identifier("search")
    static let toc = NSToolbarItem.Identifier("toc")
    static let titleLabel = NSToolbarItem.Identifier("titleLabel")  // NEW: centered title
    static let pageCount = NSToolbarItem.Identifier("pageCount")  // NEW: "3 of 12 · Ch 2 of 20"
    static let fontSize = NSToolbarItem.Identifier("fontSize")
    static let history = NSToolbarItem.Identifier("history")
    static let bookmark = NSToolbarItem.Identifier("bookmark")
    static let floatToggle = NSToolbarItem.Identifier("floatToggle")
    // NEW: replaces readingModeToggle; Apple-Books-style theme quick switcher
    static let themePopover = NSToolbarItem.Identifier("themePopover")
    // .toc, .search, .settings removed — now in menu bar only
}
