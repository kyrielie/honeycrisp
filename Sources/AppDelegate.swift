// AppDelegate.swift
//
// CHANGES vs original:
//  • "Show Table of Contents" (⌘T) added to View menu → calls ReaderViewController.toggleTOC
//  • "Search in Book" (⌘F) added to View menu → calls ReaderViewController.toggleSearch
//  • "Float on Top" moved to View menu (was already there, kept)
//  • "Show book title in menu bar" setting removed — title is now always shown
//    centered in the toolbar via ReaderViewController's .titleLabel toolbar item
//  • Settings accessible only via App menu (⌘,), never via toolbar

import AppKit
import CoreServices

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        setupMenus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.windows.isEmpty {
            let windowController = ReaderWindowController()
            windowController.showWindow(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @objc private func handleOpenEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let descriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }

        var urls: [URL] = []
        if descriptor.numberOfItems > 0 {
            for i in 1...descriptor.numberOfItems {
                if let fileDescriptor = descriptor.atIndex(i),
                   let urlString = fileDescriptor.stringValue,
                   let url = URL(string: urlString) {
                    urls.append(url)
                }
            }
        } else if let urlString = descriptor.stringValue, let url = URL(string: urlString) {
            urls.append(url)
        }

        if !urls.isEmpty { application(NSApp, open: urls) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        let epubURLs = urls.filter { $0.pathExtension.lowercased() == "epub" }
        for url in epubURLs {
            let wc = ReaderWindowController()
            wc.showWindow(nil)
            wc.loadEPUB(at: url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let wc = ReaderWindowController()
            wc.showWindow(nil)
        }
        return true
    }

    // MARK: - Menu Setup

    private func setupMenus() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // ── Application Menu ──────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(
            title: "About \(ProcessInfo.processInfo.processName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // ── File Menu ─────────────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Open…", action: #selector(openDocumentAction), keyEquivalent: "o"))

        // ── View Menu ─────────────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        // Search in Book (⌘F) — routed to the key window's ReaderViewController
        let searchItem = NSMenuItem(
            title: "Search in Book",
            action: #selector(searchInBook),
            keyEquivalent: "f"
        )
        viewMenu.addItem(searchItem)

        // Show Table of Contents (⌘T)
        let tocItem = NSMenuItem(
            title: "Show Table of Contents",
            action: #selector(showTOC),
            keyEquivalent: "t"
        )
        viewMenu.addItem(tocItem)

        viewMenu.addItem(.separator())

        // Float on Top (⇧⌘T)
        let floatItem = NSMenuItem(
            title: "Float on Top",
            action: #selector(ReaderWindowController.toggleFloat(_:)),
            keyEquivalent: "t"
        )
        floatItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(floatItem)
    }

    // MARK: - Actions

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openDocumentAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "epub")!]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB file to open"
        panel.prompt = "Open"

        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.application(NSApp, open: [url])
                }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url {
                application(NSApp, open: [url])
            }
        }
    }

    /// Forwards ⌘F to the frontmost reader window's view controller.
    @objc private func searchInBook() {
        readerVC()?.toggleSearch(nil)
    }

    /// Forwards ⌘T to the frontmost reader window's view controller.
    @objc private func showTOC() {
        readerVC()?.toggleTOC(nil)
    }

    // MARK: - Helpers

    private func readerVC() -> ReaderViewController? {
        NSApp.keyWindow?.contentViewController as? ReaderViewController
    }
}
