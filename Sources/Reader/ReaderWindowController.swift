// ReaderWindowController.swift
// Manages a single reader window: chrome, toolbar, float-on-top, multiple instances

import AppKit
import WebKit

final class ReaderWindowController: NSWindowController, NSWindowDelegate {

    private var readerViewController: ReaderViewController!
    private var isFloating = false

    // Retain all open window controllers so ARC doesn't deallocate them
    private static var openWindows: [ReaderWindowController] = []

    init() {
        let window = ReaderWindow(
            contentRect: NSRect(x: 100, y: 100, width: 780, height: 960),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let vc = ReaderViewController()
        window.contentViewController = vc

        super.init(window: window)
        self.readerViewController = vc
        window.delegate = self

        setupWindow(window)

        ReaderWindowController.openWindows.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden  // hide the title text but keep chrome
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isOpaque = true
        window.minSize = NSSize(width: 480, height: 500)
        window.isRestorable = false

        window.setContentSize(NSSize(width: 980, height: 960))  // wider to accommodate sidebar

        // The identifier keys the autosaved toolbar layout. Bump the suffix whenever the default
        // item set changes, otherwise existing installs keep the old layout and never see it.
        let toolbar = NSToolbar(identifier: "HoneycrispReaderToolbar.v2")
        toolbar.delegate = readerViewController
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        let openCount = ReaderWindowController.openWindows.count
        window.center()
        if openCount > 0 {
            let offset = CGFloat(openCount) * 20
            var frame = window.frame
            frame.origin.x += offset
            frame.origin.y -= offset
            window.setFrameOrigin(frame.origin)
        }
    }

    func loadEPUB(at url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "epub" else {
            let alert = NSAlert()
            alert.messageText = "Unsupported File"
            alert.informativeText = "Honeycrisp can open EPUB books."
            alert.alertStyle = .warning
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        readerViewController.loadEPUB(at: url)
        // Title shown only if setting is on; ReaderViewController handles this
    }

    @objc func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "epub")!]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB file to open"
        panel.prompt = "Open"

        guard let targetWindow = window else { return }
        panel.beginSheetModal(for: targetWindow) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.loadEPUB(at: url)
            }
        }
    }

    func loadRecent(_ entry: HistoryEntry) {
        guard let url = HistoryManager.shared.resolveURL(for: entry) else {
            let alert = NSAlert()
            alert.messageText = "Book Not Found"
            alert.informativeText = "\(entry.title) could not be found. The other recent books are still available."
            alert.alertStyle = .warning
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        loadEPUB(at: url)
    }

    @objc func toggleFloat(_ sender: Any?) {
        isFloating.toggle()
        if isFloating {
            window?.level = .floating
            window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window?.level = .normal
            window?.collectionBehavior = []
        }
        readerViewController.updateFloatButton(isFloating: isFloating)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        readerViewController.flushPositionSave()
        ReaderWindowController.openWindows.removeAll { $0 === self }
    }
}

// MARK: - ReaderWindow

final class ReaderWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if let vc = contentViewController as? ReaderViewController, vc.handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let vc = contentViewController as? ReaderViewController, vc.handleKeyUp(event) {
            return
        }
        super.keyUp(with: event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

}
