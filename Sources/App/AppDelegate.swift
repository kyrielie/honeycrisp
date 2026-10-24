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
//    +/-. The page-count label is shown or hidden through toolbar customization.

// swiftlint:disable file_length
import AppKit
import CoreServices
import AVFoundation

private final class BookmarkMenuContext {
    let bookmark: ReadingBookmark
    weak var reader: ReaderViewController?

    init(bookmark: ReadingBookmark, reader: ReaderViewController?) {
        self.bookmark = bookmark
        self.reader = reader
    }
}

@main
// swiftlint:disable:next type_body_length
class AppDelegate: NSObject, NSApplicationDelegate {

    /// NSApplication.delegate is weak, and Honeycrisp has no nib to instantiate the delegate.
    private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

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
        if !ReaderWindowController.hasOpenWindows {
            let windowController = ReaderWindowController()
            windowController.showWindow(nil)
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @objc private func handleOpenEvent(
        _ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let descriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }

        var urls: [URL] = []
        if descriptor.numberOfItems > 0 {
            for i in 1...descriptor.numberOfItems {
                if let fileDescriptor = descriptor.atIndex(i),
                    let urlString = fileDescriptor.stringValue,
                    let url = URL(string: urlString)
                {
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
        let supportedURLs = urls.filter { BookFormat.isSupported(url: $0) }
        let unsupported = urls.filter { !BookFormat.isSupported(url: $0) }
        if !unsupported.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Unsupported File Type"
            let skippedNames = unsupported.map(\.lastPathComponent).joined(separator: ", ")
            alert.informativeText = "Honeycrisp opens EPUB, HTML, Markdown, and Plain Text files. Unsupported items were skipped: \(skippedNames)"
            alert.alertStyle = .warning
            alert.runModal()
        }
        for url in supportedURLs {
            let wc = ReaderWindowController()
            // "New tab" means a tab of the frontmost reader window, the same
            // way Safari/Preview interpret it -- simplest option, and there's
            // no other well-defined "existing window" to prefer. If there's no
            // existing reader window, it's just a new window regardless of the
            // setting: nothing to tab onto.
            if SettingsManager.shared.newBookOpensIn == .newTab,
                let existingWindow = NSApp.orderedWindows.first(where: { $0.windowController is ReaderWindowController }
                )
            {
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

    // swiftlint:disable:next function_body_length
    private func setupMenus() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // ── Application Menu ──────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            NSMenuItem(
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
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Book Info…", action: #selector(showBookInfo), keyEquivalent: "i"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "New Window", action: #selector(newWindowAction), keyEquivalent: "n"))
        fileMenu.items.last?.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(.separator())
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

        let startItem = NSMenuItem(title: "Start Reading", action: #selector(startReading), keyEquivalent: "")
        viewMenu.addItem(startItem)
        viewMenu.addItem(NSMenuItem(title: "Go to Beginning", action: #selector(goToBeginning), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "Go to End", action: #selector(goToEnd), keyEquivalent: ""))

        viewMenu.addItem(.separator())

        // Float on Top (⇧⌘T)
        let floatItem = NSMenuItem(
            title: "Float on Top",
            action: #selector(ReaderWindowController.toggleFloat(_:)),
            keyEquivalent: "t"
        )
        floatItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(floatItem)

        // Reading mode uses a fixed title and a checkmark to show the active mode.
        let readingModeItem = NSMenuItem(
            title: "Paginated Mode",
            action: #selector(toggleReadingMode),
            keyEquivalent: "p"
        )
        readingModeItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(readingModeItem)

        // ── Go Menu ───────────────────────────────────────────────────────────
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenuItem.submenu = goMenu

        let backItem = NSMenuItem(title: "Back", action: #selector(goBack), keyEquivalent: "[")
        goMenu.addItem(backItem)
        let forwardItem = NSMenuItem(title: "Forward", action: #selector(goForward), keyEquivalent: "]")
        goMenu.addItem(forwardItem)

        goMenu.addItem(.separator())
        goMenu.addItem(NSMenuItem(title: "Start Reading", action: #selector(startReading), keyEquivalent: ""))
        goMenu.addItem(NSMenuItem(title: "Go to Beginning", action: #selector(goToBeginning), keyEquivalent: ""))
        goMenu.addItem(NSMenuItem(title: "Go to End", action: #selector(goToEnd), keyEquivalent: ""))

        goMenu.addItem(.separator())
        let chapterItems: [(String, Selector)] = [
            ("Previous Chapter", #selector(previousChapter)),
            ("Next Chapter", #selector(nextChapter)),
            ("Beginning of Chapter", #selector(chapterBeginning)),
            ("End of Chapter", #selector(chapterEnd)),
        ]
        for (title, action) in chapterItems {
            goMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }

        let bookmarksItem = NSMenuItem()
        mainMenu.addItem(bookmarksItem)
        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksMenu.delegate = self
        bookmarksItem.title = "Bookmarks"
        bookmarksItem.submenu = bookmarksMenu
        let defaultBookmarkToggle = NSMenuItem(
            title: "Add Bookmark",
            action: #selector(toggleBookmark),
            keyEquivalent: ""
        )
        defaultBookmarkToggle.target = self
        bookmarksMenu.addItem(defaultBookmarkToggle)

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
        readingMenu.addItem(
            NSMenuItem(title: "Increase Font Size", action: #selector(increaseFontSize), keyEquivalent: "+"))
        readingMenu.addItem(
            NSMenuItem(title: "Decrease Font Size", action: #selector(decreaseFontSize), keyEquivalent: "-"))

        let autoScrollMenu = NSMenu(title: "Auto-Scroll")
        autoScrollMenu.addItem(
            NSMenuItem(title: "Start / Resume", action: #selector(startAutoScroll), keyEquivalent: ""))
        autoScrollMenu.addItem(NSMenuItem(title: "Stop", action: #selector(stopAutoScroll), keyEquivalent: ""))
        autoScrollMenu.addItem(.separator())
        let autoScrollItem = NSMenuItem(title: "Auto-Scroll", action: nil, keyEquivalent: "")
        autoScrollItem.submenu = autoScrollMenu
        readingMenu.addItem(autoScrollItem)

        let speechMenu = NSMenu(title: "Speak Current Chapter")
        speechMenu.addItem(
            NSMenuItem(title: "Speak from Current Location", action: #selector(speakCurrentLocation), keyEquivalent: "")
        )
        speechMenu.addItem(NSMenuItem(title: "Pause / Resume", action: #selector(toggleSpeechPause), keyEquivalent: ""))
        speechMenu.addItem(NSMenuItem(title: "Stop Speaking", action: #selector(stopSpeech), keyEquivalent: ""))
        speechMenu.addItem(.separator())
        speechMenu.addItem(NSMenuItem(title: "Slower Speech", action: #selector(slowerSpeech), keyEquivalent: ""))
        speechMenu.addItem(NSMenuItem(title: "Faster Speech", action: #selector(fasterSpeech), keyEquivalent: ""))
        speechMenu.addItem(.separator())
        let speechItem = NSMenuItem(title: "Speak Current Chapter", action: nil, keyEquivalent: "")
        speechItem.submenu = speechMenu
        readingMenu.addItem(speechItem)

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
        windowMenu.addItem(
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            NSMenuItem(
                title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
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
            .bookInfo: #selector(showBookInfo),
            .goToBeginning: #selector(goToBeginning),
            .goToEnd: #selector(goToEnd),
            .nextChapter: #selector(nextChapter),
            .previousChapter: #selector(previousChapter),
            .toggleSpeech: #selector(toggleSpeechPause),
            .toggleAutoScroll: #selector(startAutoScroll),
            .increaseFontSize: #selector(increaseFontSize),
            .decreaseFontSize: #selector(decreaseFontSize),
            .toggleBookmark: #selector(toggleBookmark),
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

    @objc private func newWindowAction() {
        let controller = ReaderWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openSettingsAction(_ sender: Any?) {
        let controller = SettingsWindowController.shared
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openDocumentAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BookFormat.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a book or document to open"
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

    @objc private func startReading() { readerVC()?.startReading() }
    @objc private func goToBeginning() { readerVC()?.goToBeginning() }
    @objc private func goToEnd() { readerVC()?.goToEnd() }
    @objc private func showBookInfo() { readerVC()?.showBookInfo(nil) }
    @objc private func goBack() { readerVC()?.goBack() }
    @objc private func goForward() { readerVC()?.goForward() }
    @objc private func toggleBookmark() { readerVC()?.toggleBookmarkAtCurrentPosition() }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let entry = HistoryManager.shared.entries.first(where: { $0.id == id })
        else { return }
        let wc = ReaderWindowController()
        wc.showWindow(nil)
        wc.loadRecent(entry)
    }
    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkMenuContext,
            let vc = context.reader,
            let url = vc.currentBookURL(), ReadingBookmark.normalizedPath(for: url) == context.bookmark.bookPath
        else { return }
        vc.navigate(to: context.bookmark)
    }
    @objc private func removeBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        BookmarkManager.shared.remove(id: id)
        NSApp.mainMenu?.item(withTitle: "Bookmarks")?.submenu?.update()
    }
    @objc private func renameBookmark(_ sender: NSMenuItem) {
        guard let bookmark = sender.representedObject as? ReadingBookmark else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        let field = NSTextField(string: bookmark.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        BookmarkManager.shared.rename(id: bookmark.id, to: field.stringValue)
        NSApp.mainMenu?.item(withTitle: "Bookmarks")?.submenu?.update()
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

    @objc private func previousChapter() { readerVC()?.navigateChapter(forward: false) }
    @objc private func nextChapter() { readerVC()?.navigateChapter(forward: true) }
    @objc private func chapterBeginning() { readerVC()?.goToChapterBeginning() }
    @objc private func chapterEnd() { readerVC()?.goToChapterEnd() }
    @objc private func startAutoScroll() { readerVC()?.startAutoScroll() }
    @objc private func stopAutoScroll() { readerVC()?.stopAutoScroll() }
    @objc private func speakCurrentLocation() { readerVC()?.speakCurrentLocation() }
    @objc private func toggleSpeechPause() { readerVC()?.toggleSpeechPause() }
    @objc private func stopSpeech() { readerVC()?.stopSpeech() }
    @objc private func slowerSpeech() { readerVC()?.adjustSpeechRate(by: -0.05) }
    @objc private func fasterSpeech() { readerVC()?.adjustSpeechRate(by: 0.05) }

    // MARK: - Helpers

    private func readerVC() -> ReaderViewController? {
        TOCPanel.hostWindow(for: NSApp.keyWindow)?.contentViewController as? ReaderViewController
    }
}

// MARK: - NSMenuItemValidation
//
// Closes a pre-existing gap: View-menu items (Search in Book, Show TOC, and now
// Paginated Mode) were always enabled regardless of whether a book/window was
// loaded. Picked up here because it's the same mechanism already needed for the
// Paginated Mode checkmark, not separately scoped work.

extension AppDelegate: NSMenuDelegate {
    // swiftlint:disable:next function_body_length
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "View",
            let modeItem = menu.items.first(where: { $0.action == #selector(toggleReadingMode) })
        {
            modeItem.title = "Paginated Mode"
            modeItem.state = SettingsManager.shared.defaultReadingMode == .paginated ? .on : .off
            modeItem.isEnabled = readerVC() != nil
        }
        if menu.title == "Open Recent" {
            menu.items.removeAll()
            for entry in HistoryManager.shared.entries {
                let item = NSMenuItem(title: entry.title, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.isEnabled = true
                menu.addItem(item)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent), keyEquivalent: "")
            clear.target = self
            clear.isEnabled = !HistoryManager.shared.entries.isEmpty
            menu.addItem(clear)
            return
        }
        if menu.title == "Bookmarks" {
            menu.items.removeAll()
            let isBookmarked = readerVC()?.isCurrentPositionBookmarked ?? false
            let binding = SettingsManager.shared.keyBindings[.toggleBookmark]
                ?? RebindableAction.toggleBookmark.defaultBinding
            let toggle = NSMenuItem(
                title: isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                action: #selector(toggleBookmark),
                keyEquivalent: binding.key
            )
            toggle.keyEquivalentModifierMask = binding.modifierFlags
            toggle.target = self
            toggle.isEnabled = readerVC()?.currentBookURL() != nil
            menu.addItem(toggle)
            menu.addItem(.separator())
            guard let reader = readerVC(), let url = reader.currentBookURL() else { return }
            for bookmark in BookmarkManager.shared.bookmarks(for: url) {
                let item = NSMenuItem(title: bookmark.label, action: #selector(openBookmark(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = BookmarkMenuContext(bookmark: bookmark, reader: reader)
                let actions = NSMenu(title: bookmark.label)
                let rename = NSMenuItem(title: "Rename…", action: #selector(renameBookmark(_:)), keyEquivalent: "")
                rename.target = self
                rename.representedObject = bookmark
                let remove = NSMenuItem(title: "Remove", action: #selector(removeBookmark(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = bookmark.id
                actions.addItem(rename)
                actions.addItem(remove)
                item.submenu = actions
                menu.addItem(item)
            }
            return
        }
        menu.items.removeAll()
        for theme in SettingsManager.shared.themes {
            let item = NSMenuItem(title: theme.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.id
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func clearRecent() { HistoryManager.shared.clearAll() }
}

extension AppDelegate: NSMenuItemValidation {
    // swiftlint:disable:next cyclomatic_complexity
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
        if menuItem.action == #selector(goBack) {
            return readerVC()?.canGoBack ?? false
        }
        if menuItem.action == #selector(goForward) {
            return readerVC()?.canGoForward ?? false
        }
        let readingActions: [Selector?] = [
            #selector(previousChapter), #selector(nextChapter), #selector(chapterBeginning), #selector(chapterEnd),
            #selector(startAutoScroll), #selector(stopAutoScroll), #selector(speakCurrentLocation),
            #selector(toggleSpeechPause), #selector(stopSpeech), #selector(slowerSpeech), #selector(fasterSpeech),
        ]
        if readingActions.contains(menuItem.action) {
            if menuItem.action == #selector(startAutoScroll) || menuItem.action == #selector(stopAutoScroll) {
                return readerVC()?.currentBookURL() != nil && readerVC()?.currentMode == .scroll
            }
            return readerVC()?.currentBookURL() != nil
        }
        let bookActions: [Selector?] = [
            #selector(startReading), #selector(goToBeginning), #selector(goToEnd), #selector(searchInBook), #selector(showTOC),
            #selector(toggleBookmark), #selector(showBookInfo),
        ]
        if bookActions.contains(menuItem.action) {
            guard let vc = readerVC(), vc.currentBookURL() != nil else { return false }
            if menuItem.action == #selector(startReading) {
                return vc.canPerformStartReading()
            }
            return true
        }
        guard let vc = readerVC() else {
            // No reader window/content: these don't apply yet.
            return true
        }
        if menuItem.action == #selector(toggleReadingMode) {
            menuItem.state = vc.currentMode == .paginated ? .on : .off
            menuItem.title = vc.currentMode == .paginated ? "Switch to Continuous Scroll" : "Switch to Paginated Mode"
        }
        return true
    }
}
