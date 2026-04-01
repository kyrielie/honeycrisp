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
    private weak var titleLabel: NSTextField?   // centered title in toolbar

    /// Debounce timer for search input
    private var searchDebounceTimer: Timer?

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

        webView = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 920), configuration: cfg)
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.readerViewController = self

        cfg.userContentController.add(ProgressMessageHandler(owner: self), name: "progressHandler")

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
            selector: #selector(applyDynamicSettings),
            name: SettingsManager.settingsChangedNotification, object: nil)
        applyDynamicSettings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
    }

    deinit {
        searchDebounceTimer?.invalidate()
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
                    self.renderCurrentContent()
                    self.showLoading(false)
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
        do {
            let parser = EPUBParser()
            // "Format for AO3" maps to the same formatFirstChapter flag in SettingsManager
            let format = SettingsManager.shared.formatFirstChapter
            let html = try parser.buildScrollHTML(from: pkg, formatFirstChapter: format)
            let indexURL = pkg.rootFolder.appendingPathComponent(Self.readerHTMLFilename)
            try html.write(to: indexURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(indexURL, allowingReadAccessTo: pkg.rootFolder)
        } catch {
            showError(error)
        }
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

    // MARK: - Display Settings

    @objc func applyDynamicSettings() {
        let font  = SettingsManager.shared.currentFont
        let theme = SettingsManager.shared.currentTheme

        renderCurrentContent()

        let js = """
        document.documentElement.style.setProperty('--reader-font-size', '\(fontSizePercent)%');
        document.documentElement.style.setProperty('--reader-font-family', "\(font.cssValue)");
        document.documentElement.style.setProperty('--reader-bg', "\(theme.cssBackground)");
        document.documentElement.style.setProperty('--reader-text', "\(theme.cssText)");
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        switch theme {
        case .system:                          NSApp.appearance = nil
        case .dark:                            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light, .sepia, .custom:          NSApp.appearance = NSAppearance(named: .aqua)
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
        applyDynamicSettings()
    }

    // MARK: - Progress reporting

    func didReceiveProgress(_ percent: Int) {
        guard let url = currentEPUBURL else { return }
        HistoryManager.shared.updateProgress(url: url, percent: percent)
    }

    // MARK: - Navigation

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
        let font  = SettingsManager.shared.currentFont
        let theme = SettingsManager.shared.currentTheme
        let js = """
        document.documentElement.style.setProperty('--reader-font-size', '\(fontSizePercent)%');
        document.documentElement.style.setProperty('--reader-font-family', "\(font.cssValue)");
        document.documentElement.style.setProperty('--reader-bg', "\(theme.cssBackground)");
        document.documentElement.style.setProperty('--reader-text', "\(theme.cssText)");
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
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
        [.openFile, .flexibleSpace, .titleLabel, .flexibleSpace, .fontSize, .history, .floatToggle]
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
}

// MARK: - Toolbar identifier extensions

extension NSToolbarItem.Identifier {
    static let openFile    = NSToolbarItem.Identifier("openFile")
    static let titleLabel  = NSToolbarItem.Identifier("titleLabel")   // NEW: centered title
    static let fontSize    = NSToolbarItem.Identifier("fontSize")
    static let history     = NSToolbarItem.Identifier("history")
    static let floatToggle = NSToolbarItem.Identifier("floatToggle")
    // .toc, .search, .settings removed — now in menu bar only
}
