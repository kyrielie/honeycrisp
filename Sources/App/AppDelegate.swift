// AppDelegate.swift
//
// CHANGES vs original:
//  • "Show Table of Contents" (⌘T) added to View menu → calls ReaderViewController.toggleTOC
//  • "Search in Book" (⌘F) added to View menu → calls ReaderViewController.toggleSearch
//  • "Float on Top" moved to View menu (was already there, kept)
//  • "Show book title in menu bar" setting removed — title is now always shown
//    centered in the toolbar via ReaderViewController's .titleLabel toolbar item
//  • "Paginated Mode" moved out of the toolbar into Settings' General tab; the
//    View-menu item (⇧⌘P) is unchanged and still the fastest way to toggle it
//  • Settings also reachable from the reader toolbar's new gear icon, not just ⌘,
//  • Edit menu added (previously entirely absent — Cmd-C/V/A/Z in text fields
//    like the in-book search field relied on undocumented default behavior
//    without one; a first-responder Edit menu is what makes that reliable)
//  • Window menu added (previously entirely absent; standard convention for a
//    multi-window Mac app — Honeycrisp opens one ReaderWindowController per book)
//  • Reading menu added: theme picker, columns-per-screen picker, font size
//    +/-, and a "Show Page Count" toggle for the toolbar's new page-count label

import AppKit
import CoreServices

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Without this, AppKit's own automatic window tabbing (on by default)
        // fights with the explicit "new window vs new tab" setting below, and
        // is also where the automatic "Show Tab Bar" View-menu item comes from
        // -- that item is entirely AppKit-owned and disappears once automatic
        // tabbing is off, no manual menu-item removal needed or possible.
        NSWindow.allowsAutomaticWindowTabbing = false
        SettingsManager.applyAppearanceOverride(SettingsManager.shared.appearanceMode)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        setupMenus()
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncMenuShortcuts),
            name: .keyBindingsChanged, object: nil
        )
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
            // "New tab" means a tab of the frontmost reader window, the same
            // way Safari/Preview interpret it -- simplest option, and there's
            // no other well-defined "existing window" to prefer. If there's no
            // existing reader window, it's just a new window regardless of the
            // setting: nothing to tab onto.
            if SettingsManager.shared.newBookOpensIn == .newTab,
               let existingWindow = NSApp.orderedWindows.first(where: { $0.windowController is ReaderWindowController }) {
                wc.window.map { existingWindow.addTabbedWindow($0, ordered: .above) }
                wc.showWindow(nil)
            } else {
                wc.showWindow(nil)
            }
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction(_:)), keyEquivalent: ",")
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // ── File Menu ─────────────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Open…", action: #selector(openDocumentAction), keyEquivalent: "o"))
        // Standard AppKit responder-chain action — the correct way to make a
        // window's built-in close button/behavior also reachable by keyboard, and
        // what every other closable-window Mac app does. Not in RebindableAction:
        // Close, like Quit and Settings, is a fixed system-level convention, not
        // something users are offered a rebind row for.
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        // ── Edit Menu ─────────────────────────────────────────────────────────
        // Previously absent entirely. Standard items only — routed via the
        // responder chain's default NSText/NSTextView handling, same as every
        // other Mac app; nothing Honeycrisp-specific to wire here. Chiefly fixes
        // Cmd-C/V/A/Z reliability in text fields like the in-book search field
        // and Settings' custom-color hex fields, which depend on a first
        // responder Edit menu existing to validate against.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

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

        // Paginated Mode (⇧⌘P) — static title + checkmark (HIG), not a title-swap.
        // ⇧⌘P is unused today and deliberately avoids colliding with the
        // HIG-reserved plain ⌘P ("Print") convention.
        let readingModeItem = NSMenuItem(
            title: "Paginated Mode",
            action: #selector(toggleReadingMode),
            keyEquivalent: "p"
        )
        readingModeItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(readingModeItem)

        // Reflect any previously-saved rebinding immediately on launch, not only
        // after the next change.

        // ── Reading Menu ──────────────────────────────────────────────────────
        // Quick access to settings that previously required opening the Settings
        // window. These mutate SettingsManager directly (same as the toolbar's
        // own font-size control and Settings' own controls) and apply live via
        // .readerCosmeticSettingsChanged / .readerStructuralSettingsChanged,
        // which every open reader window already observes — no per-window
        // forwarding needed here the way Search/TOC/Reading-mode-toggle need.
        let readingMenuItem = NSMenuItem()
        mainMenu.addItem(readingMenuItem)
        let readingMenu = NSMenu(title: "Reading")
        readingMenuItem.submenu = readingMenu

        // Rebuilt on every opening (via the delegate below) rather than once here,
        // since themes can be renamed/added/deleted at any time from Settings or
        // the toolbar popover — a static snapshot taken at launch would go stale.
        let themeMenu = NSMenu(title: "Theme")
        themeMenu.delegate = self
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        readingMenu.addItem(themeItem)

        let colsMenu = NSMenu(title: "Columns Per Screen")
        for cols in ColsPerScreen.allCases {
            let item = NSMenuItem(title: cols.label, action: #selector(selectColsPerScreen(_:)), keyEquivalent: "")
            item.tag = cols.rawValue
            item.target = self
            colsMenu.addItem(item)
        }
        let colsItem = NSMenuItem(title: "Columns Per Screen", action: nil, keyEquivalent: "")
        colsItem.submenu = colsMenu
        readingMenu.addItem(colsItem)

        readingMenu.addItem(.separator())
        readingMenu.addItem(NSMenuItem(title: "Increase Font Size", action: #selector(increaseFontSize), keyEquivalent: "+"))
        readingMenu.addItem(NSMenuItem(title: "Decrease Font Size", action: #selector(decreaseFontSize), keyEquivalent: "-"))

        readingMenu.addItem(.separator())
        let pageCountItem = NSMenuItem(title: "Show Page Count", action: #selector(toggleShowPageCount), keyEquivalent: "")
        readingMenu.addItem(pageCountItem)

        // ── Window Menu ───────────────────────────────────────────────────────
        // Previously absent entirely. Standard convention for a multi-window Mac
        // app — Honeycrisp opens one ReaderWindowController per book. NSApp
        // populates the window list itself once this menu is assigned to
        // NSApplication.windowsMenu; Minimize/Zoom/Bring All to Front are the
        // fixed system items every app's Window menu carries.
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        // Reflect any previously-saved rebinding immediately on launch, not only
        // after the next change. Runs last since applyBindings walks the whole
        // menu tree recursively.
        syncMenuShortcuts()
    }

    // MARK: - Live menu sync (Patch 0009)
    //
    // Matches items by their bound #selector (not by title — titles are for
    // humans, selectors are stable). Honeycrisp builds its NSMenu directly in
    // setupMenus(), so the actual action selector is available and is the more
    // robust choice here than Ambrosia's title-match (Ambrosia's menu is
    // SwiftUI-CommandMenu-generated, where titles are the only handle available).

    @objc private func syncMenuShortcuts() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let bindings = SettingsManager.shared.keyBindings
        let selectorForAction: [RebindableAction: Selector] = [
            .openFile: #selector(openDocumentAction),
            .searchInBook: #selector(searchInBook),
            .showTOC: #selector(showTOC),
            .toggleFloat: #selector(ReaderWindowController.toggleFloat(_:)),
            .toggleReadingMode: #selector(toggleReadingMode),
        ]
        // Invert once: selector -> binding, so the recursive walk below is a
        // single dictionary lookup per item instead of re-scanning all five
        // actions for every menu item.
        var bindingForSelector: [Selector: KeyBinding] = [:]
        for (action, selector) in selectorForAction {
            if let binding = bindings[action] { bindingForSelector[selector] = binding }
        }
        applyBindings(bindingForSelector, to: mainMenu)
    }

    private func applyBindings(_ bindingForSelector: [Selector: KeyBinding], to menu: NSMenu) {
        for item in menu.items {
            if let action = item.action, let binding = bindingForSelector[action] {
                item.keyEquivalent = binding.key
                item.keyEquivalentModifierMask = binding.modifierFlags
            }
            if let submenu = item.submenu {
                applyBindings(bindingForSelector, to: submenu)
            }
        }
    }

    // MARK: - Actions

    @objc func openSettingsAction(_ sender: Any?) {
        let controller = SettingsWindowController.shared
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
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

    /// Forwards ⇧⌘P to the frontmost reader window's view controller.
    @objc private func toggleReadingMode() {
        readerVC()?.toggleReadingMode(nil)
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        SettingsManager.shared.currentThemeID = id
    }

    @objc private func selectColsPerScreen(_ sender: NSMenuItem) {
        guard let cols = ColsPerScreen(rawValue: sender.tag) else { return }
        SettingsManager.shared.colsPerScreen = cols
    }

    @objc private func increaseFontSize() {
        SettingsManager.shared.fontSizePercent = min(300, SettingsManager.shared.fontSizePercent + 10)
    }

    @objc private func decreaseFontSize() {
        SettingsManager.shared.fontSizePercent = max(50, SettingsManager.shared.fontSizePercent - 10)
    }

    @objc private func toggleShowPageCount() {
        SettingsManager.shared.showPageCount.toggle()
    }

    // MARK: - Helpers

    private func readerVC() -> ReaderViewController? {
        NSApp.keyWindow?.contentViewController as? ReaderViewController
    }
}

// MARK: - NSMenuItemValidation
//
// Closes a pre-existing gap: View-menu items (Search in Book, Show TOC, and now
// Paginated Mode) were always enabled regardless of whether a book/window was
// loaded. Picked up here because it's the same mechanism already needed for the
// Paginated Mode checkmark, not separately scoped work.

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.removeAll()
        for theme in SettingsManager.shared.themes {
            let item = NSMenuItem(title: theme.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.id
            item.target = self
            menu.addItem(item)
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTheme(_:)) {
            menuItem.state = (menuItem.representedObject as? UUID == SettingsManager.shared.currentThemeID) ? .on : .off
            return true
        }
        if menuItem.action == #selector(selectColsPerScreen(_:)) {
            menuItem.state = (SettingsManager.shared.colsPerScreen.rawValue == menuItem.tag) ? .on : .off
            // Only meaningful in paginated mode; grey it out in scroll mode (and
            // when there's no reader window open at all to be consistent with).
            return readerVC()?.currentMode == .paginated
        }
        if menuItem.action == #selector(toggleShowPageCount) {
            menuItem.state = SettingsManager.shared.showPageCount ? .on : .off
            return true
        }
        guard let vc = readerVC() else {
            // No reader window/content: these don't apply yet.
            return menuItem.action != #selector(toggleReadingMode)
                && menuItem.action != #selector(searchInBook)
                && menuItem.action != #selector(showTOC)
        }
        if menuItem.action == #selector(toggleReadingMode) {
            menuItem.state = vc.currentMode == .paginated ? .on : .off
        }
        return true
    }
}