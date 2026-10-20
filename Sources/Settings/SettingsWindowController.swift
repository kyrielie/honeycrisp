// SettingsWindowController.swift
//
// CHANGES vs original:
//  • TypographySettingsViewController tab removed entirely
//  • AppearanceSettingsViewController: custom font import replaced with
//    native macOS NSFontPanel; CustomFontStore kept as internal storage but
//    the "Import Font…" button is gone — users pick from installed system fonts
//  • Font family is now a free-form CSS stack (SettingsManager.fontFamily);
//    the font popup offers named presets plus "Custom…", and NSFontPanel
//    writes its picked font into fontFamily directly
//  • the General pane offers the optional generated fanfiction preface
//  • CustomFontStore and its disk-copy logic are retained so existing persisted
//    custom font names continue to work, but are no longer populated by file import
//
// CHANGES (pre-Ventura AppKit polish pass, per docs/honeycrisp-settings-window-plan.md):
//  • Window is closable-only by default; .resizable is added/removed per pane via
//    SettingsPanelWindow.resetWindowBehavior()/addResizableBehavior(). None of the
//    four current panes opt into isResizableView, but the machinery matches the
//    reference implementation so a future pane can flip it on.
//  • Tab switches now animate the window to each pane's preferred size, anchored at
//    the top-left (not the bottom), respecting Reduce Motion, with duration scaled
//    to the size delta — replaces the old fixed 520x420 frame that was too tall for
//    General and relied on Appearance's internal scroll view to paper over being too
//    short for its content.
//  • Window title, Window-menu entry, and Dock miniwindow title all update together
//    on every tab switch instead of staying hardcoded to "Settings".
//  • Window frame is autosaved so Settings reopens where the user left it.
//  • Per-tab pane sizes are cached after first resolution so switching back to an
//    already-visited tab animates directly to the cached size.

// swiftlint:disable file_length
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Pane sizing protocol

/// Conformed to by every settings pane so the tab controller can ask each one for
/// its preferred window content size and whether it wants a resizable window.
/// Mirrors SettingsPaneViewController's preferredPaneSize/isResizableView from the
/// MacAppSettingsUI reference (see macos-settings-window-guide.md §3.2).
protocol SettingsPaneSizing: AnyObject {
    var preferredPaneSize: NSSize? { get set }
    var isResizableView: Bool { get }
}

extension SettingsPaneSizing where Self: NSViewController {
    /// Resolve Auto Layout and capture the resulting frame size as the pane's
    /// preferred size. Each pane's loadView() already constructs its root NSView
    /// with an explicit, designed frame size, so this mostly just captures that
    /// value — but it goes through layoutSubtreeIfNeeded() first so a pane whose
    /// height becomes constraint-driven in the future resolves correctly too.
    func resolvePreferredPaneSize() {
        view.layoutSubtreeIfNeeded()
        preferredPaneSize = view.frame.size
    }
}

// MARK: - Window Controller

/// Every settings pane's fixed content size. All five tabs report this exact
/// same size (rather than each measuring its own content) so the window
/// never visibly resizes when switching tabs -- previously each pane
/// reported its own real content height, and NSTabViewController's own
/// toolbar-style tab switching resizes the window to match, which read as
/// "responsive" resizing the person didn't want. 560pt tall matches what
/// Appearance (the tallest tab) actually needs; shorter tabs just have
/// blank space below their content instead of a shorter window.
enum SettingsPaneMetrics {
    static let size = NSSize(width: 520, height: 560)
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: SettingsPaneMetrics.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = SettingsPaneMetrics.size
        window.maxSize = SettingsPaneMetrics.size
        // Matches the toolbar tab style (SettingsTabViewController.tabStyle =
        // .toolbar): the compact "preference window" toolbar appearance rather
        // than a full-size document-window toolbar, with the standard hairline
        // separator under it.
        window.toolbarStyle = .preference
        window.titlebarSeparatorStyle = .automatic
        // Reopen wherever the user last left it, instead of always re-centering.
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.contentViewController = SettingsTabViewController()
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Settings Window (chrome + animated per-pane resize)

/// NSWindow subclass carrying the AppKit-level chrome behavior from
/// macos-settings-window-guide.md §2: closable-only by default with opt-in
/// resizability per pane, and a top-left-anchored, Reduce-Motion-aware animated
/// resize between panes with duration scaled to the size delta.
final class SettingsPanelWindow: NSWindow {

    func resetWindowBehavior() {
        styleMask.insert([.titled, .closable])
        styleMask.remove(.resizable)
    }

    func addResizableBehavior() {
        styleMask.insert(.resizable)
    }

    private var reduceMotionIfNeeded: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Anchors growth/shrink at the top-left so the toolbar stays put while the
    /// content below it changes size, matching System Settings. Skips the
    /// animation entirely (snaps) when Reduce Motion is enabled.
    func setWindowSize(_ size: NSSize, animateIfPossible: Bool, completion: (() -> Void)? = nil) {
        let contentFrame = frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let heightDiff = frame.height - contentFrame.height
        let newFrame = NSRect(
            origin: NSPoint(x: frame.origin.x, y: frame.origin.y + heightDiff),
            size: contentFrame.size
        )

        if animateIfPossible && !reduceMotionIfNeeded {
            NSAnimationContext.runAnimationGroup(
                { ctx in
                    ctx.allowsImplicitAnimation = true
                    ctx.duration = animationResizeTime(newFrame)
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    setFrame(newFrame, display: true)
                }, completionHandler: { completion?() })
        } else {
            setFrame(newFrame, display: true)
            completion?()
        }
    }

    /// Scaled to the size delta so a tiny content change doesn't take as long as a
    /// huge one, rather than a single fixed duration for every resize.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        let minDuration: TimeInterval = 0.2
        let maxDuration: TimeInterval = 0.7
        let maxDiff = max(abs(newFrame.width - frame.width), abs(newFrame.height - frame.height))
        let referenceLength = NSScreen.main?.frame.height ?? 800
        let ratio = min(maxDiff / referenceLength, 1.0)
        return minDuration + (maxDuration - minDuration) * ratio
    }
}

// MARK: - Tab View Controller

final class SettingsTabViewController: NSTabViewController {

    /// The toolbar's own minimum content width, captured once after the first
    /// tab is actually on screen and laid out -- more accurate than guessing a
    /// constant, and this is what every pane's target width gets clamped to
    /// (see resolvedSize(for:identifier:) below) to avoid a one-frame flicker.
    private var minimumContentWidth: CGFloat?

    /// Every pane sized so far, keyed by tab identifier — avoids re-resolving
    /// Auto Layout when switching back to an already-visited tab.
    private var cachedPaneSizes: [String: NSSize] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        // Large icon+label buttons in a unified toolbar -- the actual
        // pre-Ventura "classic System Settings" tab look
        // (macos-settings-window-guide.md §1A). The default tabStyle is
        // .segmentedControlOnTop, which renders as a small pill-shaped
        // control -- that's why the tab selectors looked unchanged despite
        // everything else in the previous pass.
        tabStyle = .toolbar

        // Typography tab intentionally removed.
        struct TabSpec {
            let makeViewController: () -> NSViewController
            let label: String
            let symbol: String
        }
        let tabSpecs = [
            TabSpec(makeViewController: { GeneralSettingsViewController() }, label: "General", symbol: "gear"),
            TabSpec(
                makeViewController: { ReaderSettingsViewController() }, label: "Reading", symbol: "text.book.closed"),
            TabSpec(
                makeViewController: { AppearanceSettingsViewController() }, label: "Appearance", symbol: "paintbrush"),
            TabSpec(makeViewController: { HistorySettingsViewController() }, label: "History", symbol: "clock"),
            TabSpec(makeViewController: { ShortcutsSettingsViewController() }, label: "Shortcuts", symbol: "keyboard"),
        ]

        for spec in tabSpecs {
            let item = NSTabViewItem(viewController: spec.makeViewController())
            item.label = spec.label
            item.identifier = spec.label
            item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // First presentation: size and title the window for whichever tab
        // NSTabViewController selected by default (the first one), without
        // animating — there's nothing on screen yet to animate from.
        if let item = tabView.selectedTabViewItem {
            applyWindowBehavior(for: item, animate: false)
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem else { return }
        applyWindowBehavior(for: tabViewItem, animate: true)
    }

    private func applyWindowBehavior(for tabViewItem: NSTabViewItem, animate: Bool) {
        guard let window = view.window as? SettingsPanelWindow else { return }
        guard let pane = tabViewItem.viewController as? (NSViewController & SettingsPaneSizing) else { return }

        setWindowTitle(with: tabViewItem)

        if pane.isResizableView {
            window.addResizableBehavior()
        } else {
            window.resetWindowBehavior()
        }

        let identifier = (tabViewItem.identifier as? String) ?? tabViewItem.label
        let size = resolvedSize(for: pane, identifier: identifier)
        window.setWindowSize(size, animateIfPossible: animate)
    }

    private func resolvedSize(for pane: NSViewController & SettingsPaneSizing, identifier: String) -> NSSize {
        if let cached = cachedPaneSizes[identifier] {
            return cached
        }
        if pane.preferredPaneSize == nil {
            pane.resolvePreferredPaneSize()
        }
        var size = pane.preferredPaneSize ?? pane.view.frame.size
        size.width = max(size.width, currentMinimumContentWidth())
        cachedPaneSizes[identifier] = size
        return size
    }

    /// The toolbar imposes its own minimum content width once it's actually on
    /// screen with all four tab items in place; read it from the window's
    /// contentLayoutRect (which excludes the toolbar's own chrome) rather than
    /// guessing a constant. Falls back to 520 -- the width every pane's
    /// loadView() was actually designed around -- before the window has been
    /// shown even once.
    private func currentMinimumContentWidth() -> CGFloat {
        if let minimumContentWidth { return minimumContentWidth }
        guard let window = view.window, window.isVisible else { return 520 }
        let measured = window.contentLayoutRect.width
        guard measured > 0 else { return 520 }
        minimumContentWidth = measured
        return measured
    }

    /// Updates the title bar text, the Window menu entry, and the Dock miniwindow
    /// title together — leaving the Window menu stale is the common bug the guide
    /// calls out, so all three are set from this one call site.
    private func setWindowTitle(with tabViewItem: NSTabViewItem?) {
        guard let window = view.window else { return }
        let defaultWindowTitle = "Settings"
        window.title = tabViewItem?.label ?? defaultWindowTitle

        let windowTitle = tabViewItem.map { "\(defaultWindowTitle) — \($0.label)" } ?? defaultWindowTitle
        if window.isVisible {
            NSApp.changeWindowsItem(window, title: windowTitle, filename: false)
        } else {
            NSApp.removeWindowsItem(window)
        }
        window.miniwindowTitle = windowTitle
    }
}

// MARK: - General Settings

/// A plain NSView with AppKit's coordinate system flipped so (0,0) is the
/// top-left instead of the bottom-left. Used as the Appearance tab's scroll
/// document view so its content lays out and is initially scrolled top-down,
/// matching how top-down forms are normally built in AppKit.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class GeneralSettingsViewController: NSViewController, SettingsPaneSizing {

    var preferredPaneSize: NSSize?
    let isResizableView = false

    // swiftlint:disable:next function_body_length
    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        // No explicit spacing override: NSStackView's own default (8pt) is
        // already AppKit's standard control spacing.
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Replaces recognized fanfiction export front matter with one metadata preface.
        let formatCheckbox = NSButton(
            checkboxWithTitle: "Replace fanfiction preface",
            target: self,
            action: #selector(toggleFanficPreface(_:))
        )
        formatCheckbox.state = SettingsManager.shared.fanficPreface ? .on : .off
        stack.addArrangedSubview(formatCheckbox)
        self.formatCheckbox = formatCheckbox

        // Descriptive hint
        let hint = NSTextField(
            wrappingLabelWithString:
                "Shows a standard preface built from the book's metadata for AO3, FicHub and FicLab files. Books that cannot be read this way are unchanged."
        )
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let indentCheckbox = NSButton(
            checkboxWithTitle: "Remove paragraph indents",
            target: self,
            action: #selector(toggleRemoveParagraphIndents(_:))
        )
        indentCheckbox.state = SettingsManager.shared.removeParagraphIndents ? .on : .off
        stack.addArrangedSubview(indentCheckbox)
        self.indentCheckbox = indentCheckbox

        let indentHint = NSTextField(
            wrappingLabelWithString:
                "Strips leading whitespace used to fake first-line indentation in some books."
        )
        indentHint.font = NSFont.systemFont(ofSize: 11)
        indentHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indentHint)

        let hideImagesCheckbox = NSButton(
            checkboxWithTitle: "Hide images while reading",
            target: self,
            action: #selector(toggleHideImages(_:))
        )
        hideImagesCheckbox.state = SettingsManager.shared.hideImages ? .on : .off
        hideImagesCheckbox.toolTip = "Images remain in the book and reappear when this setting is turned off."
        stack.addArrangedSubview(hideImagesCheckbox)
        self.hideImagesCheckbox = hideImagesCheckbox

        let skipCoverCheckbox = NSButton(
            checkboxWithTitle: "Skip cover when opening",
            target: self,
            action: #selector(toggleSkipCover(_:))
        )
        skipCoverCheckbox.state = SettingsManager.shared.skipCoverWhenOpening ? .on : .off
        skipCoverCheckbox.toolTip =
            "Only applies when the EPUB explicitly marks a cover page. Saved reading positions are preserved."
        stack.addArrangedSubview(skipCoverCheckbox)
        self.skipCoverCheckbox = skipCoverCheckbox

        // Reading mode — moved here from the toolbar's paged/scroll toggle button
        // (replaced there by the Settings gear icon). This mirrors the View-menu
        // "Paginated Mode" item (⇧⌘P): it's per-window, session-only state, not a
        // persisted default (see ReaderViewController.toggleReadingMode), so this
        // checkbox reflects and drives whichever reader window is frontmost, and
        // is refreshed on viewWillAppear rather than bound to SettingsManager.
        let readingModeCheckbox = NSButton(
            checkboxWithTitle: "Paginated Mode",
            target: self,
            action: #selector(toggleReadingMode(_:))
        )
        self.readingModeCheckbox = readingModeCheckbox
        stack.addArrangedSubview(readingModeCheckbox)

        let readingModeHint = NSTextField(
            wrappingLabelWithString:
                "Show the book as fixed, swipeable columns instead of one continuous scroll. Applies to the frontmost reader window."
        )
        readingModeHint.font = NSFont.systemFont(ofSize: 11)
        readingModeHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(readingModeHint)

        // Moved here from the Appearance tab -- this is reader behavior, not
        // a cosmetic/appearance setting, so General is the better home for it.
        let linkClicksCheckbox = NSButton(
            checkboxWithTitle: "Allow link clicks",
            target: self,
            action: #selector(toggleLinkClicks(_:))
        )
        linkClicksCheckbox.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
        self.linkClicksCheckbox = linkClicksCheckbox
        stack.addArrangedSubview(linkClicksCheckbox)

        let linkClicksHint = NSTextField(
            wrappingLabelWithString:
                "Lets in-book links be clicked -- both internal cross-references (footnotes, table of contents) "
                + "and external links, which open in your default browser. On by default."
        )
        linkClicksHint.font = NSFont.systemFont(ofSize: 11)
        linkClicksHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(linkClicksHint)

        // Not a binary toggle-shaped setting the way the checkboxes above are,
        // so a segmented control rather than a checkbox.
        let newBookLabel = NSTextField(labelWithString: "New book opens in:")
        stack.addArrangedSubview(newBookLabel)

        let newBookControl = NSSegmentedControl(
            labels: NewBookOpensIn.allCases.map(\.label),
            trackingMode: .selectOne,
            target: self,
            action: #selector(newBookOpensInChanged(_:))
        )
        newBookControl.selectedSegment = SettingsManager.shared.newBookOpensIn.rawValue
        stack.addArrangedSubview(newBookControl)
        self.newBookControl = newBookControl

        let newBookHint = NSTextField(
            wrappingLabelWithString:
                "Whether opening another book creates a separate window or a tab on the frontmost reader window."
        )
        newBookHint.font = NSFont.systemFont(ofSize: 11)
        newBookHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(newBookHint)

        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(20, after: newBookHint)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let resetButton = NSButton(
            title: "Reset All to Defaults…",
            target: self,
            action: #selector(resetAllToDefaultsClicked(_:))
        )
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)
        stack.setCustomSpacing(16, after: divider)

        let resetHint = NSTextField(
            wrappingLabelWithString:
                "Resets every tab -- General, Reading, Appearance, History, and Shortcuts -- back to their original "
                + "defaults. History entries themselves aren't affected."
        )
        resetHint.font = NSFont.systemFont(ofSize: 11)
        resetHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(resetHint)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])

        self.view = root
        resolvePreferredPaneSize()

        NotificationCenter.default.addObserver(
            self, selector: #selector(readingModeSettingChanged(_:)),
            name: SettingsManager.settingsChangedNotification, object: nil
        )
    }

    private weak var readingModeCheckbox: NSButton?
    private weak var linkClicksCheckbox: NSButton?
    private weak var formatCheckbox: NSButton?
    private weak var indentCheckbox: NSButton?
    private weak var hideImagesCheckbox: NSButton?
    private weak var skipCoverCheckbox: NSButton?
    private weak var newBookControl: NSSegmentedControl?

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshReadingModeCheckbox()
        linkClicksCheckbox?.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
    }

    private func refreshReadingModeCheckbox() {
        guard frontmostReaderVC() != nil else {
            readingModeCheckbox?.state = .off
            readingModeCheckbox?.isEnabled = false
            return
        }
        readingModeCheckbox?.isEnabled = true
        readingModeCheckbox?.state = SettingsManager.shared.defaultReadingMode == .paginated ? .on : .off
    }

    @objc private func readingModeSettingChanged(_ notification: Notification) {
        refreshReadingModeCheckbox()
    }

    /// Unlike AppDelegate.readerVC()'s NSApp.keyWindow lookup (right for the
    /// View-menu toggle, since nothing else is focused then), this fires while
    /// the Settings window itself is open and focused -- which makes Settings
    /// BOTH keyWindow and mainWindow, so neither lookup ever finds the reader.
    /// Walk the app's windows in front-to-back order instead and take the
    /// first one that's actually a reader window; Settings itself won't match.
    private func frontmostReaderVC() -> ReaderViewController? {
        NSApp.orderedWindows.lazy.compactMap { $0.contentViewController as? ReaderViewController }.first
    }

    @objc private func toggleReadingMode(_ sender: NSButton) {
        guard let vc = frontmostReaderVC() else {
            refreshReadingModeCheckbox()
            return
        }
        // toggleReadingMode(_:) finishes asynchronously (it round-trips through
        // webView.evaluateJavaScript to capture the current scroll fraction before
        // switching), so vc.currentMode is still the OLD mode right after this
        // call returns. The default mode setting updates synchronously, so the
        // checkbox refreshes from that source via settingsChangedNotification.
        vc.toggleReadingMode(nil)
    }

    @objc private func toggleFanficPreface(_ sender: NSButton) {
        SettingsManager.shared.fanficPreface = sender.state == .on
    }

    @objc private func toggleRemoveParagraphIndents(_ sender: NSButton) {
        SettingsManager.shared.removeParagraphIndents = sender.state == .on
    }

    @objc private func toggleHideImages(_ sender: NSButton) {
        SettingsManager.shared.hideImages = sender.state == .on
    }

    @objc private func toggleSkipCover(_ sender: NSButton) {
        SettingsManager.shared.skipCoverWhenOpening = sender.state == .on
    }

    @objc private func toggleLinkClicks(_ sender: NSButton) {
        SettingsManager.shared.allowReaderLinkClicks = sender.state == .on
    }

    @objc private func newBookOpensInChanged(_ sender: NSSegmentedControl) {
        guard let mode = NewBookOpensIn(rawValue: sender.selectedSegment) else { return }
        SettingsManager.shared.newBookOpensIn = mode
    }

    @objc private func resetAllToDefaultsClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Reset All Settings to Defaults?"
        alert.informativeText =
            "This resets General, Appearance, History display, and Shortcuts back to their "
            + "original defaults. History entries themselves aren't affected. This can't be undone."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        SettingsManager.shared.resetAllToDefaults()

        // History observes SettingsManager.settingsChangedNotification directly
        // and refreshes from it; Shortcuts observes .keyBindingsChanged (see
        // ShortcutsSettingsViewController.reloadBindings). General's own
        // controls need a direct nudge since the reset action originates here,
        // in the same view. Appearance re-syncs on next reappearance, but only
        // when the *selected* theme ID has changed -- a reset leaves the
        // current theme selected, so if Appearance is already loaded it can
        // keep showing stale values until the user picks a different theme and
        // back; a real fix belongs in AppearanceSettingsViewController's own
        // refresh gating, not here.
        formatCheckbox?.state = SettingsManager.shared.fanficPreface ? .on : .off
        indentCheckbox?.state = SettingsManager.shared.removeParagraphIndents ? .on : .off
        hideImagesCheckbox?.state = SettingsManager.shared.hideImages ? .on : .off
        skipCoverCheckbox?.state = SettingsManager.shared.skipCoverWhenOpening ? .on : .off
        NotificationCenter.default.post(name: .readerCosmeticSettingsChanged, object: nil)
        NotificationCenter.default.post(name: .readerStructuralSettingsChanged, object: nil)
        linkClicksCheckbox?.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
        newBookControl?.selectedSegment = SettingsManager.shared.newBookOpensIn.rawValue
        refreshReadingModeCheckbox()
    }
}

final class ReaderSettingsViewController: NSViewController, SettingsPaneSizing {
    var preferredPaneSize: NSSize?
    let isResizableView = false
    private weak var speedValue: NSTextField?
    private weak var speedStepper: NSStepper?
    private weak var voicePopup: NSPopUpButton?
    private weak var adjustScrollSpeedCheckbox: NSButton?

    // swiftlint:disable:next function_body_length
    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let speedTitle = NSTextField(labelWithString: "Auto-scroll speed")
        stack.addArrangedSubview(speedTitle)
        let speedRow = NSStackView()
        speedRow.orientation = .horizontal
        speedRow.alignment = .centerY
        speedRow.spacing = 8
        let speedValue = NSTextField(labelWithString: "\(Int(SettingsManager.shared.autoScrollSpeed)) px/s")
        speedValue.widthAnchor.constraint(equalToConstant: 100).isActive = true
        speedValue.alignment = .right
        let speedStepper = NSStepper()
        speedStepper.minValue = 10
        speedStepper.maxValue = 1200
        speedStepper.increment = 25
        speedStepper.integerValue = Int(SettingsManager.shared.autoScrollSpeed)
        speedStepper.target = self
        speedStepper.action = #selector(autoScrollSpeedChanged(_:))
        speedRow.addArrangedSubview(speedValue)
        speedRow.addArrangedSubview(speedStepper)
        stack.addArrangedSubview(speedRow)

        let speedHint = NSTextField(
            wrappingLabelWithString:
                "Use the plus and minus controls to set a speed from 10 to 1,200 pixels per second. "
                + "Auto-scroll is available in continuous scroll mode.")
        speedHint.font = NSFont.systemFont(ofSize: 11)
        speedHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(speedHint)

        let adjustScrollSpeedCheckbox = NSButton(
            checkboxWithTitle: "Adjust auto-scroll speed with scroll buttons",
            target: self,
            action: #selector(toggleAdjustScrollSpeed(_:))
        )
        adjustScrollSpeedCheckbox.state = SettingsManager.shared.adjustScrollSpeedWhilePaging ? .on : .off
        stack.addArrangedSubview(adjustScrollSpeedCheckbox)

        stack.addArrangedSubview(NSTextField(labelWithString: "Speech voice"))
        let voicePopup = NSPopUpButton()
        voicePopup.addItem(withTitle: "System Default")
        voicePopup.lastItem?.representedObject = ""
        for voice in AVSpeechSynthesisVoice.speechVoices().sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            voicePopup.addItem(withTitle: "\(voice.name) (\(voice.language))")
            voicePopup.lastItem?.representedObject = voice.identifier
        }
        selectSpeechVoice(in: voicePopup, identifier: SettingsManager.shared.speechVoiceIdentifier)
        voicePopup.target = self
        voicePopup.action = #selector(speechVoiceChanged(_:))
        stack.addArrangedSubview(voicePopup)

        let speechHint = NSTextField(
            wrappingLabelWithString:
                "Speech starts at the current reading position, then continues through the remaining chapters.")
        speechHint.font = NSFont.systemFont(ofSize: 11)
        speechHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(speechHint)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        ])
        self.speedValue = speedValue
        self.speedStepper = speedStepper
        self.voicePopup = voicePopup
        self.adjustScrollSpeedCheckbox = adjustScrollSpeedCheckbox
        self.view = root
        resolvePreferredPaneSize()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        speedStepper?.integerValue = Int(SettingsManager.shared.autoScrollSpeed)
        speedValue?.stringValue = "\(Int(SettingsManager.shared.autoScrollSpeed)) px/s"
        if let voicePopup {
            selectSpeechVoice(in: voicePopup, identifier: SettingsManager.shared.speechVoiceIdentifier)
        }
    }

    private func selectSpeechVoice(in popup: NSPopUpButton, identifier: String?) {
        let representedIdentifier = identifier ?? ""
        guard
            let item = popup.itemArray.first(where: {
                ($0.representedObject as? String) == representedIdentifier
            })
        else { return }
        popup.select(item)
    }

    @objc private func autoScrollSpeedChanged(_ sender: NSStepper) {
        SettingsManager.shared.autoScrollSpeed = Double(sender.integerValue)
        speedValue?.stringValue = "\(sender.integerValue) px/s"
        if let reader = NSApp.orderedWindows.lazy.compactMap({ $0.contentViewController as? ReaderViewController })
            .first
        {
            reader.setAutoScrollSpeed(Double(sender.integerValue))
        }
    }

    @objc private func toggleAdjustScrollSpeed(_ sender: NSButton) {
        SettingsManager.shared.adjustScrollSpeedWhilePaging = sender.state == .on
    }

    @objc private func speechVoiceChanged(_ sender: NSPopUpButton) {
        let identifier = sender.selectedItem?.representedObject as? String
        let voiceIdentifier = identifier?.isEmpty == true ? nil : identifier
        let readers = NSApp.orderedWindows.compactMap { $0.contentViewController as? ReaderViewController }
        if readers.isEmpty {
            SettingsManager.shared.speechVoiceIdentifier = voiceIdentifier
        } else {
            readers.forEach { $0.setSpeechVoice(identifier: voiceIdentifier) }
        }
    }
}

// MARK: - Appearance Settings
//
// Second pass, addressing direct feedback on the first rewrite:
//  • Line height was a bare NSSlider with no visible exact value, inconsistent
//    with every other numeric control in the tab. Now a stepper with a
//    one-decimal value label, same visual language as the px steppers.
//  • Font size was shown as a percent. Now shown and edited as an actual pixel
//    number: --reader-font-size is applied to <html> as a CSS percentage
//    (EPUBParser.readerVarsCSS), and html's unstyled base size in the reader's
//    WKWebView is the standard 16px, so 100% == 16px. Converts px <-> percent
//    at the UI boundary; SettingsManager.fontSizePercent's storage format is
//    unchanged (still percent, still clamped 50-300%, i.e. 8-48px).
//  • Column 0 (labels) was right-aligned (.trailing), which combined with the
//    longest label ("Horizontal Margin:") setting the column's width, made
//    every shorter label -- and the whole form -- look shoved to the right.
//    Left-aligned (.leading) now, matching how every other left-aligned macOS
//    settings pane reads.
//  • The preview was a fixed 64pt strip above the form, too small to show a
//    real line of text at larger sizes. Moved below the form (still inside
//    the scroll view) and made responsive: no fixed height, sized by its own
//    wrapped text content at whatever width the window currently is.
// Appearance chooses an installed reader skin and edits global overrides.

// swiftlint:disable:next type_body_length
final class AppearanceSettingsViewController: NSViewController, SettingsPaneSizing {

    var preferredPaneSize: NSSize?
    let isResizableView = false

    private var lineHeightStepper: NSStepper!
    private var lineHeightLabel: NSTextField!
    private var fontSizeStepper: NSStepper!
    private var fontSizeLabel: NSTextField!
    private var maxWidthStepper: NSStepper!
    private var maxWidthLabel: NSTextField!
    private var paddingHStepper: NSStepper!
    private var paddingHLabel: NSTextField!
    private var paddingVStepper: NSStepper!
    private var paddingVLabel: NSTextField!

    private var previewBox: NSBox!
    private var previewLabel: NSTextField!
    private weak var scrollView: NSScrollView!

    private var grid: NSGridView!

    private var skinPopup: NSPopUpButton!
    private var skinDescription: NSTextField!
    private var overrideFontField: NSTextField!
    private var overrideBackgroundField: NSTextField!
    private var overrideInkField: NSTextField!
    private var overrideLinkField: NSTextField!

    /// 16px is the reader WKWebView's unstyled base root font size; --reader-font-size
    /// is applied to <html> as a CSS percentage of that. See EPUBParser.readerVarsCSS.
    private static let baseFontSizePx: Double = 16

    // swiftlint:disable:next function_body_length
    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size))

        // ── Form grid ────────────────────────────────────────────────────────
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        grid.addRow(with: [label("Reader Skin:"), makeSkinPicker()])
        grid.addRow(with: [NSGridCell.emptyContentView, makeSkinDescription()])
        grid.addRow(with: [label("Font Override:"), makeLegacyFontOverrideField()])
        grid.addRow(with: [label("Background:"), makeOverrideField(key: .background)])
        grid.addRow(with: [label("Text Color:"), makeOverrideField(key: .ink)])
        grid.addRow(with: [label("Link Color:"), makeOverrideField(key: .link)])
        grid.addRow(with: [label("Font Size:"), makeFontSizeRow()])
        grid.addRow(with: [label("Line Height:"), makeLineHeightRow()])
        grid.addRow(with: [label("Max Width:"), makeMaxWidthRow()])
        grid.addRow(with: [label("Horizontal Margin:"), makePaddingHRow()])
        grid.addRow(with: [label("Vertical Margin:"), makePaddingVRow()])
        grid.addRow(with: [label("Paragraph Indent:"), makeDecimalOverrideRow(value: SettingsManager.shared.paragraphIndent, action: #selector(paragraphIndentChanged(_:)))])
        grid.addRow(with: [label("Paragraph Spacing:"), makeDecimalOverrideRow(value: SettingsManager.shared.paragraphSpacing, action: #selector(paragraphSpacingChanged(_:)))])
        let justify = NSButton(checkboxWithTitle: "Justify text", target: self, action: #selector(justifyChanged(_:)))
        justify.state = SettingsManager.shared.justifyReaderText ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, justify])
        let hyphenate = NSButton(checkboxWithTitle: "Hyphenate text", target: self, action: #selector(hyphenateChanged(_:)))
        hyphenate.state = SettingsManager.shared.hyphenateReaderText ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, hyphenate])
        let skinActions = NSStackView(views: [makeImportSkinButton()])
        skinActions.orientation = .horizontal
        skinActions.spacing = 8
        grid.addRow(with: [NSGridCell.emptyContentView, skinActions])

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults(_:)))
        resetButton.bezelStyle = .rounded
        grid.addRow(with: [NSGridCell.emptyContentView, resetButton])

        // ── Preview (responsive: below the form, no fixed height, sized by its
        // own wrapped text at whatever width the window currently is) ────────
        previewBox = NSBox()
        previewBox.boxType = .custom
        previewBox.cornerRadius = 8
        previewBox.borderWidth = 1
        previewBox.borderColor = .separatorColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        previewLabel = NSTextField(
            wrappingLabelWithString:
                "The quick brown fox jumps over the lazy dog. Reading is the sole means by which we slip, involuntarily, often helplessly, into another's skin."
        )
        previewLabel.isEditable = false
        previewLabel.isSelectable = false
        previewLabel.isBezeled = false
        previewLabel.drawsBackground = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewBox.contentView?.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: previewBox.contentView!.leadingAnchor, constant: 16),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.contentView!.trailingAnchor, constant: -16),
            previewLabel.topAnchor.constraint(equalTo: previewBox.contentView!.topAnchor, constant: 16),
            previewLabel.bottomAnchor.constraint(equalTo: previewBox.contentView!.bottomAnchor, constant: -16),
        ])

        // ── Scroll view (Appearance's content is taller than the window) ─────
        let formStack = NSStackView(views: [grid, previewBox])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 20
        formStack.translatesAutoresizingMaskIntoConstraints = false
        previewBox.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true

        let clipContainer = FlippedView()
        clipContainer.translatesAutoresizingMaskIntoConstraints = false
        clipContainer.addSubview(formStack)
        NSLayoutConstraint.activate([
            formStack.topAnchor.constraint(equalTo: clipContainer.topAnchor, constant: 20),
            formStack.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor, constant: -20),
            formStack.bottomAnchor.constraint(equalTo: clipContainer.bottomAnchor, constant: -20),
        ])

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = clipContainer
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // A scroll view pinned flush to the window's top edge, directly under
        // a .preference-style toolbar, gets a translucent "scroll edge effect"
        // material from AppKit when its content scrolls -- that's the visible
        // color difference versus the other tabs (none of which have a scroll
        // view touching the top edge the same way). Not needed here since this
        // tab's toolbar-adjacent area is a static header, not scrolling
        // content that benefits from the effect.
        if #available(macOS 13.3, *) {
            scrollView.automaticallyAdjustsContentInsets = false
        }
        self.scrollView = scrollView

        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // documentView's width tracks the scroll view's clip view, so only
            // vertical scrolling happens and the preview reflows to the window's
            // actual width -- that's what "responsive" means here, since there's
            // no independent width to give it other than the window's own.
            clipContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        self.view = root
        // Skin options and the preview can exceed the shared pane height;
        // the internal scroll view handles the remaining content.
        resolvePreferredPaneSize()

        refreshSkinDescription()
        refreshPreview()
    }

    private enum OverrideField: String { case font, background, ink, link }

    // MARK: - Control Factories

    private func makeDecimalOverrideRow(value: Double, action: Selector) -> NSView {
        let field = NSTextField(string: String(value))
        field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        field.target = self
        field.action = action
        let units = NSTextField(labelWithString: "em")
        let row = NSStackView(views: [field, units])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    @objc private func paragraphIndentChanged(_ sender: NSTextField) {
        SettingsManager.shared.paragraphIndent = Double(sender.stringValue) ?? 0.3
    }

    @objc private func paragraphSpacingChanged(_ sender: NSTextField) {
        SettingsManager.shared.paragraphSpacing = Double(sender.stringValue) ?? 0.5
    }

    @objc private func justifyChanged(_ sender: NSButton) { SettingsManager.shared.justifyReaderText = sender.state == .on }
    @objc private func hyphenateChanged(_ sender: NSButton) { SettingsManager.shared.hyphenateReaderText = sender.state == .on }

    private func makeSkinPicker() -> NSPopUpButton {
        skinPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        reloadSkinPicker()
        skinPopup.target = self
        skinPopup.action = #selector(skinChanged(_:))
        return skinPopup
    }

    private func reloadSkinPicker() {
        SkinStore.shared.reload()
        skinPopup?.removeAllItems()
        for skin in SkinStore.shared.skins {
            skinPopup?.addItem(withTitle: skin.name)
            skinPopup?.lastItem?.representedObject = skin.id
        }
        if let index = SkinStore.shared.skins.firstIndex(where: { $0.id == SettingsManager.shared.readerSkinID }) {
            skinPopup?.selectItem(at: index)
        }
    }

    private func makeSkinDescription() -> NSTextField {
        skinDescription = NSTextField(wrappingLabelWithString: "")
        skinDescription.textColor = .secondaryLabelColor
        skinDescription.maximumNumberOfLines = 2
        return skinDescription
    }

    private func makeLegacyFontOverrideField() -> NSTextField {
        let field = NSTextField(string: SettingsManager.shared.readerFontOverride)
        field.placeholderString = "Use skin default"
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        field.target = self
        field.action = #selector(readerOverrideChanged(_:))
        overrideFontField = field
        return field
    }

    private func refreshSkinDescription() {
        let skin = SkinStore.shared.skin(id: SettingsManager.shared.readerSkinID)
        skinDescription?.stringValue = [skin?.creator, skin?.version.map { "Version \($0)" }, skin?.license.map { _ in "License included" },
                                        skin?.lowContrast == true ? "Low contrast" : nil,
                                        skin?.fontImports.isEmpty == false ? "Uses web fonts (not downloaded)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func makeOverrideField(key: OverrideField) -> NSTextField {
        let value: String
        switch key {
        case .font: value = SettingsManager.shared.readerFontOverride
        case .background: value = SettingsManager.shared.readerBackgroundOverride
        case .ink: value = SettingsManager.shared.readerInkOverride
        case .link: value = SettingsManager.shared.readerLinkOverride
        }
        let field = NSTextField(string: value)
        field.placeholderString = "Use skin color"
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        field.target = self
        field.action = #selector(readerOverrideChanged(_:))
        field.identifier = NSUserInterfaceItemIdentifier("reader-override-\(key.rawValue)")
        switch key {
        case .font: overrideFontField = field
        case .background: overrideBackgroundField = field
        case .ink: overrideInkField = field
        case .link: overrideLinkField = field
        }
        return field
    }

    private func makeImportSkinButton() -> NSButton {
        let button = NSButton(title: "Install Skin…", target: self, action: #selector(importSkin(_:)))
        button.bezelStyle = .rounded
        return button
    }

    private func makeClearOverridesButton() -> NSButton {
        let button = NSButton(title: "Clear Overrides", target: self, action: #selector(clearReaderOverrides(_:)))
        button.bezelStyle = .rounded
        return button
    }

    @objc private func skinChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        SettingsManager.shared.readerSkinID = id
        refreshSkinDescription()
        refreshPreview()
    }

    @objc private func readerOverrideChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender.identifier?.rawValue {
        case "reader-override-font": SettingsManager.shared.readerFontOverride = value
        case "reader-override-background": SettingsManager.shared.readerBackgroundOverride = value
        case "reader-override-ink": SettingsManager.shared.readerInkOverride = value
        case "reader-override-link": SettingsManager.shared.readerLinkOverride = value
        default: break
        }
        refreshPreview()
    }

    @objc private func clearReaderOverrides(_ sender: Any?) {
        SettingsManager.shared.clearReaderOverrides()
        [overrideFontField, overrideBackgroundField, overrideInkField, overrideLinkField].forEach { $0?.stringValue = "" }
        refreshPreview()
    }

    @objc private func importSkin(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .directory]
        panel.message = "Choose a .nnwtheme skin folder or ZIP archive."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isZip = url.pathExtension.lowercased() == "zip" || values?.isDirectory != true
        do {
            let skin = try isZip
                ? SkinStore.shared.importSkin(zipURL: url)
                : SkinStore.shared.importSkin(from: url)
            reloadSkinPicker()
            if let index = SkinStore.shared.skins.firstIndex(where: { $0.id == skin.id }) {
                skinPopup.selectItem(at: index)
                SettingsManager.shared.readerSkinID = skin.id
            }
            refreshSkinDescription()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Belt-and-suspenders on top of `clipContainer` being flipped: also
    /// explicitly scroll to top every time this tab appears, so re-opening
    /// Settings after switching tabs or resizing the window doesn't leave a
    /// stale scroll position either.
    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        scrollView?.contentView.scroll(to: .zero)
        scrollView?.reflectScrolledClipView(scrollView.contentView)
        reloadSkinPicker()
        refreshSkinDescription()
        refreshPreview()
    }

    private func makeLineHeightRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let stepper = NSStepper()
        stepper.minValue = 1.0
        stepper.maxValue = 3.0
        stepper.increment = 0.1
        stepper.doubleValue = SettingsManager.shared.lineHeight
        stepper.target = self
        stepper.action = #selector(lineHeightStepperChanged(_:))
        stepper.setAccessibilityLabel("Line Height")
        stepper.setAccessibilityValueDescription(String(format: "%.1f", SettingsManager.shared.lineHeight))
        lineHeightStepper = stepper

        let valueLabel = NSTextField(labelWithString: String(format: "%.1f", SettingsManager.shared.lineHeight))
        valueLabel.font = NSFont.systemFont(ofSize: 13)
        lineHeightLabel = valueLabel

        row.addArrangedSubview(stepper)
        row.addArrangedSubview(valueLabel)
        return row
    }

    /// Single parameterized factory for the remaining integer px steppers
    /// (max width / h margin / v margin). Font size has its own row below
    /// since it displays px while storing percent underneath.
    // swiftlint:disable:next function_parameter_count
    private func makeStepperRow(
        label accessibilityName: String,
        min: Double, max: Double, increment: Double,
        initialValue: Int,
        action: Selector,
        stepper stepperOut: inout NSStepper!, valueLabel valueLabelOut: inout NSTextField!
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let stepper = NSStepper()
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = increment
        stepper.integerValue = initialValue
        stepper.target = self
        stepper.action = action
        stepper.setAccessibilityLabel(accessibilityName)
        stepper.setAccessibilityValueDescription("\(initialValue) pixels")
        stepperOut = stepper

        let valueLabel = NSTextField(labelWithString: "\(initialValue)px")
        valueLabel.font = NSFont.systemFont(ofSize: 13)
        valueLabelOut = valueLabel

        row.addArrangedSubview(stepper)
        row.addArrangedSubview(valueLabel)
        return row
    }

    /// Displays and edits the reader's root font size as an actual pixel
    /// number rather than a percentage -- see baseFontSizePx's doc comment.
    private func makeFontSizeRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let currentPx = Self.px(fromPercent: SettingsManager.shared.fontSizePercent)
        let stepper = NSStepper()
        stepper.minValue = Double(Self.px(fromPercent: 50))  // matches fontSizePercent's stored clamp (50-300%)
        stepper.maxValue = Double(Self.px(fromPercent: 300))
        stepper.increment = 1
        stepper.integerValue = currentPx
        stepper.target = self
        stepper.action = #selector(fontSizeStepperChanged(_:))
        stepper.setAccessibilityLabel("Font Size")
        stepper.setAccessibilityValueDescription("\(currentPx) pixels")
        fontSizeStepper = stepper

        let valueLabel = NSTextField(labelWithString: "\(currentPx)px")
        valueLabel.font = NSFont.systemFont(ofSize: 13)
        fontSizeLabel = valueLabel

        row.addArrangedSubview(stepper)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private static func px(fromPercent percent: Int) -> Int {
        Int((Double(percent) / 100.0 * baseFontSizePx).rounded())
    }

    private static func percent(fromPx px: Int) -> Int {
        Int((Double(px) / baseFontSizePx * 100.0).rounded())
    }

    private func makeMaxWidthRow() -> NSView {
        makeStepperRow(
            label: "Max Width", min: 320, max: 1400, increment: 20,
            initialValue: SettingsManager.shared.maxWidth,
            action: #selector(maxWidthStepperChanged(_:)),
            stepper: &maxWidthStepper, valueLabel: &maxWidthLabel
        )
    }

    private func makePaddingHRow() -> NSView {
        makeStepperRow(
            label: "Horizontal Margin", min: 0, max: 120, increment: 4,
            initialValue: SettingsManager.shared.paddingH,
            action: #selector(paddingHStepperChanged(_:)),
            stepper: &paddingHStepper, valueLabel: &paddingHLabel
        )
    }

    private func makePaddingVRow() -> NSView {
        makeStepperRow(
            label: "Vertical Margin", min: 0, max: 120, increment: 4,
            initialValue: SettingsManager.shared.paddingV,
            action: #selector(paddingVStepperChanged(_:)),
            stepper: &paddingVStepper, valueLabel: &paddingVLabel
        )
    }

    // MARK: - Visibility

    private func refreshPreview() {
        let settings = SettingsManager.shared
        let skin = SkinStore.shared.skin(id: settings.readerSkinID)
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tokens = isDark ? (skin?.dark ?? skin?.light) : skin?.light
        let colors = settings.effectiveColorSet
        let background = settings.readerBackgroundOverride.isEmpty ? (tokens?.background ?? colors.background) : settings.readerBackgroundOverride
        let text = settings.readerInkOverride.isEmpty ? (tokens?.ink ?? colors.text) : settings.readerInkOverride
        previewBox.fillColor = SettingsManager.color(fromCSS: background)
        previewLabel.textColor = SettingsManager.color(fromCSS: text)

        let px = Self.px(fromPercent: settings.fontSizePercent)
        let firstFamily = settings.effectiveReaderFontFamily
            .split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? ""
        let previewFont =
            NSFont(name: firstFamily, size: CGFloat(px))
            ?? NSFont.systemFont(ofSize: CGFloat(px))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = SettingsManager.shared.lineHeight
        previewLabel.attributedStringValue = NSAttributedString(
            string: previewLabel.stringValue,
            attributes: [
                .font: previewFont,
                .foregroundColor: previewLabel.textColor ?? .labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    // MARK: - Actions

    @objc private func lineHeightStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.lineHeight = sender.doubleValue
        lineHeightLabel.stringValue = String(format: "%.1f", sender.doubleValue)
        sender.setAccessibilityValueDescription(String(format: "%.1f", sender.doubleValue))
        refreshPreview()
    }

    @objc private func fontSizeStepperChanged(_ sender: NSStepper) {
        let px = sender.integerValue
        SettingsManager.shared.fontSizePercent = Self.percent(fromPx: px)
        fontSizeLabel.stringValue = "\(px)px"
        sender.setAccessibilityValueDescription("\(px) pixels")
        refreshPreview()
    }

    @objc private func maxWidthStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.maxWidth = sender.integerValue
        maxWidthLabel.stringValue = "\(SettingsManager.shared.maxWidth)px"
        sender.setAccessibilityValueDescription("\(SettingsManager.shared.maxWidth) pixels")
    }

    @objc private func paddingHStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.paddingH = sender.integerValue
        paddingHLabel.stringValue = "\(SettingsManager.shared.paddingH)px"
        sender.setAccessibilityValueDescription("\(SettingsManager.shared.paddingH) pixels")
    }

    @objc private func paddingVStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.paddingV = sender.integerValue
        paddingVLabel.stringValue = "\(SettingsManager.shared.paddingV)px"
        sender.setAccessibilityValueDescription("\(SettingsManager.shared.paddingV) pixels")
    }

    @objc private func resetToDefaults(_ sender: NSButton) {
        SettingsManager.shared.resetReaderToDefaults()
        overrideFontField.stringValue = ""
        overrideBackgroundField.stringValue = ""
        overrideInkField.stringValue = ""
        overrideLinkField.stringValue = ""
        lineHeightStepper.doubleValue = SettingsManager.shared.lineHeight
        lineHeightLabel.stringValue = String(format: "%.1f", SettingsManager.shared.lineHeight)
        fontSizeStepper.integerValue = 16
        fontSizeLabel.stringValue = "16px"
        maxWidthStepper.integerValue = SettingsManager.shared.maxWidth
        maxWidthLabel.stringValue = "\(SettingsManager.shared.maxWidth)px"
        paddingHStepper.integerValue = SettingsManager.shared.paddingH
        paddingHLabel.stringValue = "\(SettingsManager.shared.paddingH)px"
        paddingVStepper.integerValue = SettingsManager.shared.paddingV
        paddingVLabel.stringValue = "\(SettingsManager.shared.paddingV)px"
        refreshSkinDescription()
        refreshPreview()
    }

}

// MARK: - History Settings

final class HistorySettingsViewController: NSViewController, SettingsPaneSizing {

    var preferredPaneSize: NSSize?
    let isResizableView = false
    private var tableView: NSTableView!
    private var historyEntries: [HistoryEntry] = []

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        col.width = 480
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView

        let clearBtn = NSButton(title: "Clear History", target: self, action: #selector(clearHistory(_:)))
        clearBtn.bezelStyle = .rounded
        clearBtn.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(clearBtn)

        NSLayoutConstraint.activate([
            // 20pt insets, matching every other settings tab, instead of the
            // 10pt this tab used to use on its own.
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: clearBtn.topAnchor, constant: -12),

            clearBtn.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            clearBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        self.view = root
        // Same reasoning as Appearance: the history list can grow arbitrarily
        // long, so the preferred size is the shared pane height
        // (SettingsPaneMetrics.size) and the internal NSScrollView (not the
        // window) absorbs the rest.
        resolvePreferredPaneSize()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: SettingsManager.settingsChangedNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: HistoryManager.entriesDidChangeNotification, object: nil
        )
        historyEntries = HistoryManager.shared.entries
    }

    @objc private func reload() {
        historyEntries = HistoryManager.shared.entries
        tableView.reloadData()
    }

    @objc private func clearHistory(_ sender: Any?) {
        HistoryManager.shared.clearAll()
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

extension HistorySettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        historyEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard historyEntries.indices.contains(row) else { return nil }
        let entry = historyEntries[row]
        let cell = HistorySettingsCellView()
        cell.configure(with: entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // Unlike the toolbar popover (which opens in the current reader window),
    // clicking a book here opens it in a brand-new window -- Settings isn't
    // tied to any single open book the way the popover is. Mirrors the
    // ReaderWindowController-per-book pattern AppDelegate.application(open:)
    // already uses for Finder/dock opens.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard historyEntries.indices.contains(row) else { return }
        let entry = historyEntries[row]
        HistoryEntryOpener.open(
            entry,
            onOpen: { url in
                let wc = ReaderWindowController()
                wc.showWindow(nil)
                wc.loadEPUB(at: url)
            },
            onRemoved: { [weak self] in
                self?.reload()
            })
    }
}

final class HistorySettingsCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with entry: HistoryEntry) {
        titleLabel.stringValue =
            entry.title.isEmpty
            ? entry.url.deletingPathExtension().lastPathComponent
            : entry.title

        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        let dateStr = fmt.localizedString(for: entry.openedAt, relativeTo: Date())
        let pctStr = entry.readingProgressPercent > 0 ? "\(entry.readingProgressPercent)% read" : "Not started"
        detailLabel.stringValue = "\(dateStr) • \(pctStr)"
    }
}

// MARK: - CustomFontStore
// Retained for backwards-compatibility with persisted custom font names.
// No longer populated via file import; NSFontPanel writes directly to SettingsManager.customFontName.

struct CustomFont: Codable {
    let id: UUID
    let name: String  // PostScript name
    let filename: String
}

final class CustomFontStore {
    static let shared = CustomFontStore()
    private init() { load() }

    private(set) var fonts: [CustomFont] = []

    var selectedFontID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: "customSelectedFontID") else { return nil }
            return UUID(uuidString: str)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "customSelectedFontID") }
    }

    private var storageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("CustomFonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func save() {
        if let data = try? JSONEncoder().encode(fonts) {
            UserDefaults.standard.set(data, forKey: "customFontsList")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "customFontsList"),
            let decoded = try? JSONDecoder().decode([CustomFont].self, from: data)
        else { return }
        fonts = decoded
        // Re-register any previously imported font files with Core Text
        for font in fonts {
            let url = storageDir.appendingPathComponent(font.filename)
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
