// ReaderViewController.swift
// Core reading experience: WebKit rendering, scrolling, toolbar, keyboard nav

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

    // FIX (Bug 2): fontSizePercent is no longer a local instance variable.
    // It is now read from and written to SettingsManager (which persists it in
    // UserDefaults), so the value survives window closes and app restarts.
    private var fontSizePercent: Int {
        get { SettingsManager.shared.fontSizePercent }
        set { SettingsManager.shared.fontSizePercent = newValue }
    }

    // Toolbar items
    private weak var floatButton: NSButton?
    private weak var historyButton: NSButton?

    // MARK: - View Lifecycle

    override func loadView() {
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false

        let cfg = WKWebViewConfiguration()
        cfg.preferences = prefs
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = .nonPersistent()

        webView = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 920), configuration: cfg)
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")

        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        let root = NSVisualEffectView()
        root.material = .contentBackground
        root.blendingMode = .behindWindow
        root.state = .active

        root.addSubview(webView)
        root.addSubview(loadingIndicator)

        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(applyDynamicSettings), name: SettingsManager.settingsChangedNotification, object: nil)

        // FIX (Bug 3): Apply the persisted theme immediately on load so the
        // window appearance (NSApp.appearance) is set before any content loads.
        // Previously this only ran after a WebView navigation finished, so a
        // cold launch with no EPUB would leave the window white in dark mode.
        applyDynamicSettings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view.window)
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        NotificationCenter.default.removeObserver(self)
    }

    private func beginSecurityAccess(for url: URL) {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
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

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.currentPackage = pkg
                    self.view.window?.title = pkg.title.isEmpty ? url.deletingPathExtension().lastPathComponent : pkg.title
                    HistoryManager.shared.record(url: url, title: pkg.title)
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
            let html = try parser.buildScrollHTML(from: pkg)
            let indexURL = pkg.rootFolder.appendingPathComponent(Self.readerHTMLFilename)
            try html.write(to: indexURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(indexURL, allowingReadAccessTo: pkg.rootFolder)
        } catch {
            showError(error)
        }
    }

    // MARK: - Display Settings

    @objc func applyDynamicSettings() {
        let font = SettingsManager.shared.currentFont
        let theme = SettingsManager.shared.currentTheme

        // Apply CSS custom properties to the live page
        let js = """
        document.documentElement.style.setProperty('--reader-font-size', '\(fontSizePercent)%');
        document.documentElement.style.setProperty('--reader-font-family', "\(font.cssValue)");
        document.documentElement.style.setProperty('--reader-bg', "\(theme.cssBackground)");
        document.documentElement.style.setProperty('--reader-text', "\(theme.cssText)");
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        // FIX (Bug 3): This appearance override now runs eagerly from viewDidLoad
        // (not only after a page finishes loading), so the window chrome is
        // correctly dark/light immediately, even before any EPUB is opened.
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light, .sepia:
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    @objc private func adjustFontSize(_ sender: NSSegmentedControl) {
        let segment = sender.selectedSegment

        // FIX (Bug 2): Write back through the computed property so SettingsManager
        // persists the new value. Previously this mutated a local Int that was
        // discarded on the next launch.
        if segment == 0 {
            fontSizePercent = max(50, fontSizePercent - 10)
        } else if segment == 1 {
            fontSizePercent = min(300, fontSizePercent + 10)
        }

        DispatchQueue.main.async {
            if segment != -1 {
                sender.setSelected(false, forSegment: segment)
            }
        }

        // applyDynamicSettings is triggered by the SettingsManager notification,
        // but call it directly too so the WebView updates without a round-trip delay.
        applyDynamicSettings()
    }

    // MARK: - Navigation

    func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 123, 126, 116: // Left, Up, Page Up
            scrollByPages(-1)
        case 124, 125, 121: // Right, Down, Page Down
            scrollByPages(1)
        default:
            break
        }
    }

    private func scrollByPages(_ pages: Int) {
        let js = "window.scrollBy({ top: \(pages) * window.innerHeight, behavior: 'smooth' });"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Toolbar updates

    func updateFloatButton(isFloating: Bool) {
        floatButton?.image = NSImage(systemSymbolName: isFloating ? "pin.fill" : "pin", accessibilityDescription: "Float on top")
        floatButton?.contentTintColor = isFloating ? .systemOrange : nil
    }

    // MARK: - Helpers

    private func showLoading(_ loading: Bool) {
        loadingIndicator.isHidden = !loading
        if loading { loadingIndicator.startAnimation(nil) }
        else { loadingIndicator.stopAnimation(nil) }
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

    // Actions
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
}

// MARK: - WKNavigationDelegate
extension ReaderViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyDynamicSettings()
    }
}

// MARK: - NSToolbarDelegate
extension ReaderViewController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openFile, .flexibleSpace, .fontSize, .space, .history, .floatToggle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .openFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = makeToolbarButton(symbol: "folder", tooltip: "Open EPUB…", action: #selector(openFile(_:)))
            item.label = "Open"
            return item

        case .fontSize:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let seg = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "textformat.size.smaller", accessibilityDescription: "Decrease Font")!,
                    NSImage(systemSymbolName: "textformat.size.larger", accessibilityDescription: "Increase Font")!
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(adjustFontSize(_:))
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
        let btn = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!, target: self, action: action)
        btn.bezelStyle = .texturedRounded
        btn.toolTip = tooltip
        btn.isBordered = false
        btn.setButtonType(.momentaryPushIn)
        return btn
    }

    @objc private func floatAction(_ sender: Any?) {
        (view.window?.windowController as? ReaderWindowController)?.toggleFloat(sender)
    }
}

// MARK: - ReaderWebView
final class ReaderWebView: WKWebView {
    weak var readerViewController: ReaderViewController?
    override func keyDown(with event: NSEvent) {
        let navigationKeys: Set<UInt16> = [123, 124, 125, 126, 116, 121]
        if navigationKeys.contains(event.keyCode), let vc = readerViewController {
            vc.handleKeyDown(event)
        } else {
            super.keyDown(with: event)
        }
    }
    override var acceptsFirstResponder: Bool { true }
}

extension NSToolbarItem.Identifier {
    static let openFile    = NSToolbarItem.Identifier("openFile")
    static let fontSize    = NSToolbarItem.Identifier("fontSize")
    static let history     = NSToolbarItem.Identifier("history")
    static let floatToggle = NSToolbarItem.Identifier("floatToggle")
}
