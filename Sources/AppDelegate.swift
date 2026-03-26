import AppKit
import CoreServices

class AppDelegate: NSObject, NSApplicationDelegate {

    // 1. Hook into the app lifecycle right before it finishes launching
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Intercept the macOS "Open Document" Apple Event (odoc)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    // 2. Process the Apple Event payload natively
    @objc private func handleOpenEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        // Grab the direct object parameter from the event (this contains the files)
        guard let descriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        
        var urls: [URL] = []
        
        // Apple Events usually package files as a 1-indexed list (typeAEList)
        if descriptor.numberOfItems > 0 {
            for i in 1...descriptor.numberOfItems {
                if let fileDescriptor = descriptor.atIndex(i),
                   let urlString = fileDescriptor.stringValue,
                   let url = URL(string: urlString) {
                    urls.append(url)
                }
            }
        } else if let urlString = descriptor.stringValue, let url = URL(string: urlString) {
            // Fallback just in case a single unlisted item is passed
            urls.append(url)
        }
        
        // 3. Forward to your existing AppDelegate open logic
        if !urls.isEmpty {
            self.application(NSApp, open: urls)
        }
    }


    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // FIX: Handle opening EPUBs from Finder (Double-click / Open With)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.pathExtension.lowercased() == "epub" else { return }
        
        if let existingWindowController = NSApp.windows.first?.windowController as? ReaderWindowController {
            existingWindowController.loadEPUB(at: url)
            existingWindowController.window?.makeKeyAndOrderFront(nil)
        } else {
            let newWindowController = ReaderWindowController()
            newWindowController.showWindow(nil)
            newWindowController.loadEPUB(at: url)
        }
    }

    // FIX: Reopen a window if the user clicks the Dock icon and no windows are visible
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

        // 1. Application Menu
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

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        
        // FIX: Route the Open menu item to the App Delegate's custom open document action
        fileMenu.addItem(NSMenuItem(title: "Open...", action: #selector(openDocumentAction), keyEquivalent: "o"))
        
        // 3. View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let toggleItem = NSMenuItem(title: "Float on Top", action: #selector(ReaderWindowController.toggleFloat(_:)), keyEquivalent: "t")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleItem)
    }

    @objc private func openSettings() {
        // Assuming SettingsWindowController exists based on your original code
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }
    
    // FIX: Global Open action that works even when all windows are closed
    @objc private func openDocumentAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "epub")!]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB file to open"
        panel.prompt = "Open"
        
        // If there's an active window, attach it as a sheet. Otherwise, show as a standalone modal.
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
