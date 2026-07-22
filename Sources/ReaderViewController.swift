// ReaderViewController.swift
// Core reading experience: WebKit rendering, scrolling, toolbar, keyboard nav,
// TOC sidebar, in-book search, reading-progress tracking, dynamic title.
//
// CHANGES vs original:
//  • Toolbar: removed .search, .toc, .settings items; added centered .titleLabel item
//  • Title: always shown centered in toolbar (truncated); window.title stays empty
//  • TOC: driven entirely from menu bar "Show Table of Contents" (⌘T); sidebar
//    collapsed/expanded state is independent of toolbar buttons
//  • TOC re-open bug fixed: setSidebarVisible checks collapsed state via splitView API
//  • Search: moved to menu bar (⌘F); debounced via a 0.3 s Timer
//  • Search highlighting: window.searchText() now returns count AND highlights via
//    CSS mark elements injected by the JS embedded in the HTML template
//  • Settings button removed from toolbar (accessible only via menu bar)
//  • "Format for AO3" rename propagated; EPUBParser receives updated flag name

import AppKit
import WebKit

final class ReaderViewController: NSViewController {

    // MARK: - State

    private var webView: ReaderWebView!
    private var loadingIndicator: NSProgressIndicator!

    private var currentPackage: EPUBPackage?
    private var currentEPUBURL: URL?

    // MARK: - Pagination state (Patch 0007)

    /// Initialized from SettingsManager.shared.defaultReadingMode when a book is
    /// loaded — deliberately not read from or written to HistoryEntry. Every
    /// window opens in whatever the current global default is.
    private(set) var currentMode: ReadingMode = .scroll
    private var paginationEngine: PaginationEngine?
    private var currentSpineIndex: Int = 0
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
    private var pendingPaginatedRestorePosition: RestorePosition = .start
    private var securityScopedURL: URL?

    private static let readerHTMLFilename = "_ql_reader.html"

    private var fontSizePercent: Int {
        get { SettingsManager.shared.fontSizePercent }
        set { SettingsManager.shared.fontSizePercent = newValue }
    }

    // MARK: - Child VCs

    private var tocSidebar: TOCSidebarViewController!
    private var searchBarVC: SearchBarViewController!

    // MARK: - Layout

    private var splitView: NSSplitView!
    private var sidebarContainer: NSView!
    private var contentContainer: NSView!
    private var searchOverlay: NSView!
    private var searchBarVisible = false

    // MARK: - Toolbar

    /// Weak refs to toolbar controls that need state updates
    private weak var floatButton: NSButton?
    private weak var historyButton: NSButton?
    private weak var readingModeButton: NSButton?
    private weak var titleLabel: NSTextField?   // centered title in toolbar

    /// Debounce timer for search input
    private var searchDebounceTimer: Timer?

    /// Debounce timer for structural settings changes (avoids re-rendering on every
    /// intermediate value while a slider/stepper is being dragged).
    private var structuralSettingsDebounceTimer: Timer?

    /// Periodic position save while a book is open (mirrors Ambrosia's saveTimer) —
    /// belt-and-suspenders alongside the debounced-scroll save, so a reader who
    /// stops scrolling and just sits reading still gets saved periodically.
    private var positionSaveTimer: Timer?

    // MARK: - View Lifecycle

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

        // Registered before the WKWebView is constructed — Ambrosia's invariant 6
        // requires this ordering. WebKit usually tolerates late registration
        // since content hasn't loaded yet, but that's not guaranteed, so align
        // with the documented-safe order rather than relying on it.
        msgController.add(ProgressMessageHandler(owner: self), name: "progressHandler")
        msgController.add(PositionMessageHandler(owner: self), name: "positionHandler")
        msgController.add(PageActionMessageHandler(owner: self), name: "pageAction")
        msgController.add(PositionUpdateMessageHandler(owner: self), name: "positionUpdate")

        webView = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 920), configuration: cfg)
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.readerViewController = self

        paginationEngine = PaginationEngine(webView: webView)

        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        // ── TOC sidebar ───────────────────────────────────────────────────────
        tocSidebar = TOCSidebarViewController()
        tocSidebar.delegate = self

        sidebarContainer = NSView()
        sidebarContainer.wantsLayer = true

        addChild(tocSidebar)
        sidebarContainer.addSubview(tocSidebar.view)
        tocSidebar.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tocSidebar.view.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            tocSidebar.view.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            tocSidebar.view.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            tocSidebar.view.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])

        // ── Content (webView + search overlay) ───────────────────────────────
        contentContainer = NSView()

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
        addChild(searchBarVC)
        searchOverlay = searchBarVC.view
        searchOverlay.translatesAutoresizingMaskIntoConstraints = false
        searchOverlay.isHidden = true
        contentContainer.addSubview(searchOverlay)
        NSLayoutConstraint.activate([
            searchOverlay.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 12),
            searchOverlay.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            searchOverlay.widthAnchor.constraint(equalToConstant: 380),
            searchOverlay.heightAnchor.constraint(equalToConstant: 44),
        ])

        contentContainer.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
        ])

        // ── Split view ────────────────────────────────────────────────────────
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        splitView.addArrangedSubview(sidebarContainer)
        splitView.addArrangedSubview(contentContainer)

        // ── Root ─────────────────────────────────────────────────────────────
        let root = NSVisualEffectView()
        root.material = .contentBackground
        root.blendingMode = .behindWindow
        root.state = .active

        root.addSubview(splitView)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root

        // Sidebar starts collapsed
        setSidebarVisible(false, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self,
            selector: #selector(applyCosmeticCSSUpdate),
            name: .readerCosmeticSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(scheduleStructuralReload),
            name: .readerStructuralSettingsChanged, object: nil)
        applyDynamicSettings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
        if currentMode == .paginated {
            installScrollWheelMonitorIfNeeded()
            installKeyDownMonitor()
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
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Security

    private func beginSecurityAccess(for url: URL) {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
    }

    // MARK: - EPUB Loading

    func loadEPUB(at url: URL) {
        currentEPUBURL = url
        showLoading(true)
        beginSecurityAccess(for: url)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("EPUBReader_\(UUID().uuidString)")
                let parser = EPUBParser()
                let extracted = try parser.unpackEPUB(at: url, to: workDir)
                let pkg = try parser.parsePackage(at: extracted)

                let tocParser = TOCParser()
                let tocEntries = tocParser.parseTOC(for: pkg)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.currentPackage = pkg
                    // Always show title centered in toolbar; never in window chrome
                    let title = pkg.title.isEmpty
                        ? url.deletingPathExtension().lastPathComponent
                        : pkg.title
                    self.setToolbarTitle(title)
                    HistoryManager.shared.record(url: url, title: pkg.title)
                    self.tocSidebar.load(entries: tocEntries)

                    self.currentMode = SettingsManager.shared.defaultReadingMode
                    self.applyScrollbarVisibility()
                    self.updateReadingModeButton()
                    if self.currentMode == .paginated {
                        self.installScrollWheelMonitorIfNeeded()
                        if let saved = HistoryManager.shared.savedPosition(for: url) {
                            self.currentSpineIndex = min(saved.spineIndex, max(0, pkg.spineURLs.count - 1))
                            self.pendingPaginatedRestorePosition = saved.characterOffset > 0
                                ? .characterOffset(saved.characterOffset) : .start
                        }
                    }

                    self.renderCurrentContent()
                    self.showLoading(false)
                    self.startPositionSaveTimer()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showLoading(false)
                    self?.showError(error)
                }
            }
        }
    }

    private func renderCurrentContent() {
        guard let pkg = currentPackage else { return }
        switch currentMode {
        case .scroll:
            renderScrollContent(pkg: pkg)
        case .paginated:
            loadSpineItem(index: currentSpineIndex, restorePosition: pendingPaginatedRestorePosition, pkg: pkg)
        }
    }

    private func renderScrollContent(pkg: EPUBPackage) {
        do {
            let parser = EPUBParser()
            // "Format for AO3" maps to the same formatFirstChapter flag in SettingsManager
            let format = SettingsManager.shared.formatFirstChapter
            let removeIndents = SettingsManager.shared.removeParagraphIndents
            let html = try parser.buildScrollHTML(from: pkg, formatFirstChapter: format, removeParagraphIndents: removeIndents)
            let indexURL = pkg.rootFolder.appendingPathComponent(Self.readerHTMLFilename)
            try html.write(to: indexURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(indexURL, allowingReadAccessTo: pkg.rootFolder)
        } catch {
            showError(error)
        }
    }

    /// Loads a single spine item in paginated mode, with the column layout CSS
    /// baked into the HTML before load (never injected after, to avoid an
    /// unstyled flash before repagination). `pendingRestorePosition` is applied by
    /// `PaginationEngine.applyLayout` from `webView(_:didFinish:)`.
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
        pendingPaginatedRestorePosition = restorePosition
        do {
            let parser = EPUBParser()
            let format = SettingsManager.shared.formatFirstChapter
            let removeIndents = SettingsManager.shared.removeParagraphIndents
            let bounds = webView.bounds.isEmpty ? NSRect(x: 0, y: 0, width: 780, height: 920) : webView.bounds
            let html = try parser.buildPageHTML(
                from: pkg, spineIndex: index,
                viewportWidth: bounds.width, viewportHeight: bounds.height,
                colsPerScreen: SettingsManager.shared.colsPerScreen,
                maxWidth: CGFloat(SettingsManager.shared.maxWidth),
                paddingH: CGFloat(SettingsManager.shared.paddingH),
                paddingV: CGFloat(SettingsManager.shared.paddingV),
                formatFirstChapter: format, removeParagraphIndents: removeIndents
            )
            let indexURL = pkg.rootFolder.appendingPathComponent(Self.readerHTMLFilename)
            try html.write(to: indexURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(indexURL, allowingReadAccessTo: pkg.rootFolder)
        } catch {
            showError(error)
        }
    }

    /// Called from PaginationEngine.spineNavigationHandler when a page turn runs
    /// past the current spine item's last/first column.
    private func navigateSpine(forward: Bool) {
        guard let pkg = currentPackage else { return }
        let next = currentSpineIndex + (forward ? 1 : -1)
        guard next >= 0 && next < pkg.spineURLs.count else { return }
        loadSpineItem(index: next, restorePosition: forward ? .start : .end, pkg: pkg)
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

    /// Wired to the View-menu "Paginated Mode" item (⇧⌘P) and the .readingModeToggle
    /// toolbar button. Reloads the current content in the new mode at the
    /// equivalent fraction-based position. Mode isn't persisted per-file — nothing
    /// is written back to HistoryEntry here (SettingsManager.defaultReadingMode,
    /// the global default, is untouched by this toggle too; it only flips this
    /// window's currentMode for its current session).
    @objc func toggleReadingMode(_ sender: Any?) {
        guard let pkg = currentPackage else { return }
        let goingTo: ReadingMode = currentMode == .scroll ? .paginated : .scroll

        if goingTo == .paginated {
            // Scroll mode's own progress fraction (scrollY / scrollHeight) becomes
            // the paginated spine item's restore fraction. Spine index carries over
            // as-is — scroll mode has no notion of "which spine item", so index 0
            // (the merged document's start) is the only thing to hand off; this is
            // an approximation, not lossless, since scroll mode's fraction is over
            // the WHOLE book while paginated mode's fraction is over ONE spine item.
            webView.evaluateJavaScript("(window.scrollY + window.innerHeight) / document.documentElement.scrollHeight") { [weak self] result, _ in
                guard let self else { return }
                self.currentMode = .paginated
                self.applyScrollbarVisibility()
                self.installScrollWheelMonitorIfNeeded()
                self.installKeyDownMonitor()
                self.updateReadingModeButton()
                let fraction = (result as? Double) ?? 0
                self.loadSpineItem(index: 0, restorePosition: .fraction(fraction), pkg: pkg)
            }
        } else {
            currentMode = .scroll
            applyScrollbarVisibility()
            removeScrollWheelMonitor()
            removeKeyDownMonitor()
            updateReadingModeButton()
            renderScrollContent(pkg: pkg)
        }
    }

    private func updateReadingModeButton() {
        let isPaginated = currentMode == .paginated
        readingModeButton?.contentTintColor = isPaginated ? .systemOrange : nil
        readingModeButton?.toolTip = isPaginated ? "Scroll Mode" : "Paginated Mode"
    }

    // MARK: - Toolbar Title

    /// Sets the centered title label in the toolbar (truncated to a reasonable length).
    private func setToolbarTitle(_ title: String) {
        // Ensure the window title is always blank — we only show it in the toolbar
        view.window?.title = ""
        titleLabel?.stringValue = title
    }

    // MARK: - TOC Sidebar

    /// Returns whether the sidebar is currently expanded (not collapsed).
    private var isSidebarVisible: Bool {
        // NSSplitView considers a subview collapsed when its frame width is 0
        return !splitView.isSubviewCollapsed(sidebarContainer)
    }

    private func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        let targetWidth: CGFloat = visible ? 220 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                splitView.animator().setPosition(targetWidth, ofDividerAt: 0)
            }
        } else {
            splitView.setPosition(targetWidth, ofDividerAt: 0)
        }
    }

    /// Called from AppDelegate menu action and keyboard shortcut (⌘T).
    @objc func toggleTOC(_ sender: Any?) {
        setSidebarVisible(!isSidebarVisible)
    }

    // MARK: - Search

    /// Called from AppDelegate menu action and keyboard shortcut (⌘F).
    @objc func toggleSearch(_ sender: Any?) {
        searchBarVisible.toggle()
        searchOverlay.isHidden = !searchBarVisible

        if searchBarVisible {
            view.window?.makeFirstResponder(searchOverlay)
        } else {
            searchDebounceTimer?.invalidate()
            webView.evaluateJavaScript("window.searchText('')", completionHandler: nil)
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
        webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            var comps = URLComponents(string: "https://www.google.com/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = comps.url { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - Display Settings

    /// Full initial apply on load — sets every CSS var and the window appearance.
    /// Subsequent changes go through `applyCosmeticCSSUpdate` or
    /// `scheduleStructuralReload` instead, not this.
    @objc func applyDynamicSettings() {
        applyCosmeticCSSUpdate()
        applyWindowAppearance()
    }

    /// JS-only live patch of the `#honeycrisp-vars` `<style>` element's textContent —
    /// no reload, so scroll position and any other DOM state survive a font/theme/
    /// line-height tweak. `EPUBParser.readerVarsCSS` defines the same custom properties
    /// as the initial defaults this replaces.
    @objc private func applyCosmeticCSSUpdate() {
        let s = SettingsManager.shared
        // fontFamily is free-form (Ambrosia-style) and most presets contain single
        // quotes (e.g. "'Iowan Old Style', Georgia, serif"), so it can't be
        // interpolated directly into the single-quoted JS string below — that
        // breaks the JS (syntax error) and silently drops every var update below
        // it, since evaluateJavaScript's completionHandler is nil here. Encode it
        // as a proper JS string literal instead.
        let fontFamilyLiteral = Self.jsStringLiteral(s.fontFamily)
        let js = """
        (function() {
          var el = document.getElementById('honeycrisp-vars');
          if (!el) return;
          el.textContent = ':root {' +
            '--reader-font-size:\(s.fontSizePercent)%;' +
            '--reader-font-family:' + \(fontFamilyLiteral) + ';' +
            '--reader-bg:\(s.effectiveBackgroundCSS);' +
            '--reader-text:\(s.effectiveTextCSS);' +
            '--reader-line-height:\(s.lineHeight);' +
            '--reader-max-width:\(s.maxWidth)px;' +
            '--reader-padding-h:\(s.paddingH)px;' +
            '--reader-link-pointer-events:\(s.allowReaderLinkClicks ? "auto" : "none");' +
          '}';
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        applyWindowAppearance()
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

    private func applyWindowAppearance() {
        switch SettingsManager.shared.currentTheme {
        case .system:                  NSApp.appearance = nil
        case .dark:                    NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light, .sepia, .custom:  NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    /// Debounced (~0.15s) full reload for structural settings changes (formatting
    /// flags, pagination layout). A plain Timer, matching the rest of the codebase's
    /// style rather than introducing a dedicated debounce utility for one call site.
    @objc private func scheduleStructuralReload() {
        structuralSettingsDebounceTimer?.invalidate()
        structuralSettingsDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self, let url = self.currentEPUBURL else { self?.renderCurrentContent(); return }
            // Capture current position first so restoreSavedPositionIfAvailable (fired
            // from the reload's own didFinish) lands back where the reader actually
            // was, not wherever they were the last time the book was opened.
            self.webView.evaluateJavaScript("window.honeycrispCurrentCharacterOffset ? window.honeycrispCurrentCharacterOffset() : 0") { result, _ in
                if let offset = result as? Int {
                    HistoryManager.shared.updatePosition(url: url, spineIndex: 0, characterOffset: offset)
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
        guard let url = currentEPUBURL else { return }
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
        HistoryManager.shared.updatePosition(url: url, spineIndex: currentSpineIndex, characterOffset: offset)
    }

    private func startPositionSaveTimer() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.flushPositionSave()
        }
    }

    /// Best-effort synchronous-as-possible flush: queries the current offset via JS
    /// and saves it immediately, rather than waiting for the next debounced-scroll or
    /// periodic tick. Called when a reader closes the window or navigates away —
    /// without this, quitting mid-page loses however much time elapsed since the
    /// last periodic tick. Also called after every paginated column navigation
    /// (via didReceivePositionUpdate), since PaginationJS's own scroll events don't
    /// drive readerJS's debounced-scroll save path the way scroll mode's do.
    func flushPositionSave() {
        guard let url = currentEPUBURL else { return }
        let spineIndex = currentSpineIndex
        webView.evaluateJavaScript("window.honeycrispCurrentCharacterOffset ? window.honeycrispCurrentCharacterOffset() : 0") { result, _ in
            guard let offset = result as? Int else { return }
            HistoryManager.shared.updatePosition(url: url, spineIndex: spineIndex, characterOffset: offset)
        }
    }

    /// Called after the reader HTML finishes loading, in scroll mode only —
    /// paginated mode's restore goes through PaginationEngine.applyLayout's
    /// .characterOffset case instead (set up in loadEPUB/loadSpineItem). If a
    /// saved offset exists for this URL, seeks to it; otherwise leaves the book at
    /// the top, matching current (never-restores) behaviour for first opens.
    private func restoreSavedPositionIfAvailable() {
        guard let url = currentEPUBURL,
              let saved = HistoryManager.shared.savedPosition(for: url),
              saved.characterOffset > 0
        else { return }
        webView.evaluateJavaScript("window.honeycrispNavigateToOffset(\(saved.characterOffset));", completionHandler: nil)
    }

    /// PaginationJS's qlNextPage/qlPrevPage post this when a page turn runs past
    /// the current spine item's last/first column.
    func didReceivePageAction(forward: Bool) {
        navigateSpine(forward: forward)
    }

    /// PaginationJS posts this after every column navigation (page turn or
    /// restore). Reuses the same flushPositionSave path scroll mode's debounced
    /// scroll listener drives, rather than a separate paginated-only scheme.
    func didReceivePositionUpdate() {
        flushPositionSave()
    }

    // MARK: - Navigation

    /// Scroll-mode-only now: paginated-mode arrow/PageUp/PageDown handling moved
    /// to `installKeyDownMonitor`, which intercepts those keys before WebKit's
    /// own default keyboard-scroll action ever sees them (see that method's doc
    /// comment). This is only still reachable in scroll mode, where there's no
    /// competing native horizontal-scroll handler to race.
    func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 123, 126, 116: scrollByPages(-1)
        case 124, 125, 121: scrollByPages(1)
        case 3 where event.modifierFlags.contains(.command): // ⌘F
            toggleSearch(nil)
        default: break
        }
    }

    private func scrollByPages(_ pages: Int) {
        let js = "window.scrollBy({ top: \(pages) * window.innerHeight, behavior: 'smooth' });"
        webView.evaluateJavaScript(js, completionHandler: nil)
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
                guard event.momentumPhase.isEmpty else { return nil } // swallow momentum
                // No phase at all: legacy mouse wheel. Keep the old per-event
                // deadzone behavior since there's no .began/.changed/.ended
                // gesture to accumulate here.
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
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
                  responder.isDescendant(of: self.view) else { return event }

            switch event.keyCode {
            case 123, 126, 116: // ← ↑ Page Up
                guard !event.isARepeat else { return nil }
                self.paginationEngine?.handleKeyDown(.backward)
                return nil
            case 124, 125, 121: // → ↓ Page Down
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
            self.paginationEngine?.currentFraction { fraction in
                self.loadSpineItem(index: self.currentSpineIndex, restorePosition: .fraction(fraction), pkg: pkg)
            }
        }
    }

    // MARK: - Toolbar updates

    func updateFloatButton(isFloating: Bool) {
        floatButton?.image = NSImage(
            systemSymbolName: isFloating ? "pin.fill" : "pin",
            accessibilityDescription: "Float on top"
        )
        floatButton?.contentTintColor = isFloating ? .systemOrange : nil
    }

    // MARK: - Helpers

    private func showLoading(_ loading: Bool) {
        loadingIndicator.isHidden = !loading
        if loading { loadingIndicator.startAnimation(nil) }
        else        { loadingIndicator.stopAnimation(nil) }
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

    @objc private func readingModeToggleAction(_ sender: Any?) {
        toggleReadingMode(sender)
    }

    @objc private func floatAction(_ sender: Any?) {
        (view.window?.windowController as? ReaderWindowController)?.toggleFloat(sender)
    }
}

// MARK: - TOCSidebarDelegate

extension ReaderViewController: TOCSidebarDelegate {

    func tocSidebar(_ sidebar: TOCSidebarViewController, didSelectEntry entry: TOCEntry) {
        guard let pkg = currentPackage else { return }

        let hrefBase = entry.href.components(separatedBy: "#").first ?? entry.href
        let decodedBase = hrefBase.removingPercentEncoding ?? hrefBase

        if let idx = pkg.spineURLs.firstIndex(where: { url in
            url.lastPathComponent == URL(fileURLWithPath: decodedBase).lastPathComponent
        }) {
            let fragment = entry.href.components(separatedBy: "#").dropFirst().first
            if let frag = fragment, !frag.isEmpty {
                let safe = frag.replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("window.navigateToFragment('\(safe)');", completionHandler: nil)
            } else {
                webView.evaluateJavaScript("window.navigateToChapter(\(idx));", completionHandler: nil)
            }
        } else {
            webView.evaluateJavaScript("window.navigateToChapter(0);", completionHandler: nil)
        }
    }
}

// MARK: - SearchBarDelegate

extension ReaderViewController: SearchBarDelegate {

    /// Debounce search so JS evaluation only fires 0.3 s after the user stops typing.
    func searchBar(_ bar: SearchBarViewController, didSearch term: String) {
        searchDebounceTimer?.invalidate()
        guard !term.isEmpty else {
            webView.evaluateJavaScript("window.searchText('');", completionHandler: nil)
            bar.resultCount = 0
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self, weak bar] _ in
            guard let self, let bar else { return }
            let safe = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            // window.searchText() highlights all matches and returns the count
            self.webView.evaluateJavaScript("window.searchText('\(safe)');") { result, _ in
                bar.resultCount = result as? Int ?? 0
            }
        }
    }

    func searchBarDidRequestNext(_ bar: SearchBarViewController) {
        webView.evaluateJavaScript("window.nextSearchResult(1);", completionHandler: nil)
    }

    func searchBarDidRequestPrevious(_ bar: SearchBarViewController) {
        webView.evaluateJavaScript("window.nextSearchResult(-1);", completionHandler: nil)
    }

    func searchBarDidDismiss(_ bar: SearchBarViewController) {
        searchBarVisible = false
        searchOverlay.isHidden = true
        searchDebounceTimer?.invalidate()
        webView.evaluateJavaScript("window.searchText('')", completionHandler: nil)
        bar.clear()
        view.window?.makeFirstResponder(webView)
    }
}

// MARK: - NSSplitViewDelegate

extension ReaderViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 160 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 320 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === sidebarContainer }
    func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool { true }
}

// MARK: - WKNavigationDelegate

extension ReaderViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated,
           let url = action.request.url,
           url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The initial HTML bakes in the readerVarsCSS defaults, not the user's actual
        // saved values — apply them now via the same path settings changes use, so
        // there's one definition of "what the CSS vars should be", not two.
        applyCosmeticCSSUpdate()
        switch currentMode {
        case .scroll:
            restoreSavedPositionIfAvailable()
        case .paginated:
            paginationEngine?.setColsPerScreen(SettingsManager.shared.colsPerScreen)
            paginationEngine?.applyLayout(restorePosition: pendingPaginatedRestorePosition)
        }
    }
}

// MARK: - NSToolbarDelegate
//
// Toolbar items:  [openFile] [flexibleSpace] [titleLabel] [flexibleSpace] [fontSize] [history] [floatToggle]
//
// Removed vs original: .toc, .search, .settings
// Added:               .titleLabel (centered, truncated book title)

extension ReaderViewController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openFile, .flexibleSpace, .titleLabel, .flexibleSpace, .fontSize, .readingModeToggle, .history, .floatToggle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {

        case .openFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = makeToolbarButton(symbol: "folder", tooltip: "Open EPUB…", action: #selector(openFile(_:)))
            item.label = "Open"
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
            titleLabel = label
            item.view = label
            item.label = ""
            item.minSize = NSSize(width: 60, height: 24)
            item.maxSize = NSSize(width: 340, height: 24)
            return item

        case .fontSize:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let seg = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "textformat.size.smaller", accessibilityDescription: "Decrease Font")!,
                    NSImage(systemSymbolName: "textformat.size.larger",  accessibilityDescription: "Increase Font")!
                ],
                trackingMode: .momentary, target: self, action: #selector(adjustFontSize(_:))
            )
            seg.segmentStyle = .separated
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

        case .readingModeToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = makeToolbarButton(symbol: "rectangle.split.2x1", tooltip: "Paginated Mode", action: #selector(readingModeToggleAction(_:)))
            readingModeButton = btn
            item.view = btn
            item.label = "Pages"
            return item

        case .floatToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = makeToolbarButton(symbol: "pin", tooltip: "Float on top", action: #selector(floatAction(_:)))
            floatButton = btn
            item.view = btn
            item.label = "Float"
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
        btn.setButtonType(.momentaryPushIn)
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
/// mode's debounced scroll listener drives.
private class PositionUpdateMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderViewController?
    init(owner: ReaderViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.didReceivePositionUpdate()
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
            title: "Search in Browser",
            action: #selector(ReaderViewController.searchSelectionInBrowser),
            keyEquivalent: ""
        )
        searchItem.target = readerViewController
        menu.insertItem(searchItem, at: 0)

        super.willOpenMenu(menu, with: event)
    }
}

// MARK: - Toolbar identifier extensions

extension NSToolbarItem.Identifier {
    static let openFile    = NSToolbarItem.Identifier("openFile")
    static let titleLabel  = NSToolbarItem.Identifier("titleLabel")   // NEW: centered title
    static let fontSize    = NSToolbarItem.Identifier("fontSize")
    static let history     = NSToolbarItem.Identifier("history")
    static let floatToggle = NSToolbarItem.Identifier("floatToggle")
    static let readingModeToggle = NSToolbarItem.Identifier("readingModeToggle")
    // .toc, .search, .settings removed — now in menu bar only
}