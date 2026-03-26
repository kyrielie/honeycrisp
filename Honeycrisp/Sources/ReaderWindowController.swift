// ReaderWindowController.swift
// Manages a single reader window: chrome, toolbar, float-on-top, multiple instances

import AppKit
import WebKit
import UniformTypeIdentifiers

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
        window.titleVisibility = .hidden          // hide the title text but keep chrome
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isOpaque = true
        window.minSize = NSSize(width: 420, height: 500)

        window.setContentSize(NSSize(width: 780, height: 960))

        let toolbar = NSToolbar(identifier: "ReaderToolbar_\(UUID().uuidString.prefix(8))")
        toolbar.delegate = readerViewController
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let openCount = ReaderWindowController.openWindows.count
        if openCount == 0 {
            window.center()
        } else {
            window.center()
            let offset = CGFloat(openCount) * 20
            var frame = window.frame
            frame.origin.x += offset
            frame.origin.y -= offset
            window.setFrameOrigin(frame.origin)
        }
    }

    func loadEPUB(at url: URL) {
        readerViewController.loadEPUB(at: url)
        window?.title = url.deletingPathExtension().lastPathComponent
    }

    @objc func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "epub")!]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB file to open"
        panel.prompt = "Open"

        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.loadEPUB(at: url)
            }
        }
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
        ReaderWindowController.openWindows.removeAll { $0 === self }
    }
}

// Custom window subclass to forward key events to view controller
final class ReaderWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if let vc = contentViewController as? ReaderViewController {
            vc.handleKeyDown(event)
        } else {
            super.keyDown(with: event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
