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
        
        if !urls.isEmpty {
            self.application(NSApp, open: urls)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // FIX (Bug 4): Each URL always opens in a brand-new window.
    // Previously the code checked NSApp.windows.first and reused it, which meant
    // every Open With / double-click clobbered whatever was already being read.
    // Multiple EPUBs passed at once (e.g. drag a batch onto the Dock icon) each
    // get their own window, staggered so they don't perfectly overlap.
    func application(_ application: NSApplication, open urls: [URL]) {
        let epubURLs = urls.filter { $0.pathExtension.lowercased() == "epub" }
        for url in epubURLs {
            let windowController = ReaderWindowController()
            windowController.showWindow(nil)
            windowController.loadEPUB(at: url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let windowController = ReaderWindowController()
            windowController.showWindow(nil)
        }
        return true
    }

    private func setupMenus() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        
        appMenu.addItem(NSMenuItem(title: "About \(ProcessInfo.processInfo.processName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Open...", action: #selector(openDocumentAction), keyEquivalent: "o"))

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let toggleItem = NSMenuItem(title: "Float on Top", action: #selector(ReaderWindowController.toggleFloat(_:)), keyEquivalent: "t")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleItem)
    }

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
                self.application(NSApp, open: [url])
            }
        }
    }
}
