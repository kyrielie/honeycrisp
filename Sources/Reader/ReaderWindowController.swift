// ReaderWindowController.swift
// Manages a single reader window: chrome, toolbar, float-on-top, multiple instances

import AppKit
import WebKit

final class ReaderWindowController: NSWindowController, NSWindowDelegate {

    private var readerViewController: ReaderViewController!
    private var isFloating = false

    // Retain all open window controllers so ARC doesn't deallocate them
    private static var openWindows: [ReaderWindowController] = []

    static var hasOpenWindows: Bool {
        !openWindows.isEmpty
    }

    static var openCount: Int {
        openWindows.count
    }

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

    func loadDocument(at url: URL) {
        loadEPUB(at: url)
    }

    func loadEPUB(at url: URL) {
        guard url.isFileURL, BookFormat.isSupported(url: url) else {
            let alert = NSAlert()
            alert.messageText = "Unsupported File"
            alert.informativeText = "Honeycrisp opens EPUB, HTML, Markdown, and Plain Text files."
            alert.alertStyle = .warning
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        readerViewController.loadEPUB(at: url)
        // Title shown only if setting is on; ReaderViewController handles this
    }

    @objc func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BookFormat.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a book or document to open"
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

    // MARK: - NSDraggingDestination via NSWindowDelegate

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = sender.droppedSupportedURLs(), !urls.isEmpty else {
            return []
        }
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.droppedSupportedURLs(), !urls.isEmpty else {
            return false
        }
        return true
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.droppedSupportedURLs(), !urls.isEmpty else {
            return false
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.application(NSApp, open: urls)
            return true
        }
        return false
    }
}

// MARK: - ReaderWindow

final class ReaderWindow: NSWindow {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        registerForDraggedTypes([.fileURL])
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = sender.droppedSupportedURLs(), !urls.isEmpty else {
            return []
        }
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.droppedSupportedURLs(), !urls.isEmpty else {
            return false
        }
        return true
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.droppedSupportedURLs(), !urls.isEmpty else {
            return false
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.application(NSApp, open: urls)
            return true
        }
        return false
    }

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

extension NSDraggingInfo {
    func droppedSupportedURLs() -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else { return nil }
        let valid = urls.filter { BookFormat.isSupported(url: $0) }
        return valid.isEmpty ? nil : valid
    }
}
