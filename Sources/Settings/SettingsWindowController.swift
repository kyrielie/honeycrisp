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
//  • "Format first chapter" checkbox renamed to "Format for AO3"
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

import AppKit
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

/// Every settings pane's fixed content size. All four tabs report this exact
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
            NSAnimationContext.runAnimationGroup({ ctx in
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
        let tabSpecs: [(() -> NSViewController, String, String)] = [
            ({ GeneralSettingsViewController() },    "General",    "gear"),
            ({ AppearanceSettingsViewController() }, "Appearance", "paintbrush"),
            ({ HistorySettingsViewController() },    "History",    "clock"),
            ({ ShortcutsSettingsViewController() },  "Shortcuts",  "keyboard"),
        ]

        for (makeVC, label, symbol) in tabSpecs {
            let vc = makeVC()
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.identifier = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        // No explicit spacing override: NSStackView's own default (8pt) is
        // already AppKit's standard control spacing.
        stack.translatesAutoresizingMaskIntoConstraints = false

        // "Format for AO3" (renamed from "Format first chapter")
        let formatCheckbox = NSButton(
            checkboxWithTitle: "Format for AO3",
            target: self,
            action: #selector(toggleFormatForAO3(_:))
        )
        formatCheckbox.state = SettingsManager.shared.formatFirstChapter ? .on : .off
        stack.addArrangedSubview(formatCheckbox)
        self.formatCheckbox = formatCheckbox

        // Descriptive hint
        let hint = NSTextField(wrappingLabelWithString:
            "Removes all toc-heading elements and enlarges calibre2 elements globally across the book."
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

        let indentHint = NSTextField(wrappingLabelWithString:
            "Strips leading whitespace used to fake first-line indentation in some books."
        )
        indentHint.font = NSFont.systemFont(ofSize: 11)
        indentHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indentHint)

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

        let readingModeHint = NSTextField(wrappingLabelWithString:
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

        let linkClicksHint = NSTextField(wrappingLabelWithString:
            "Lets in-book links be clicked -- both internal cross-references (footnotes, table of contents) and external links, which open in your default browser. On by default."
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

        let newBookHint = NSTextField(wrappingLabelWithString:
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

        let resetHint = NSTextField(wrappingLabelWithString:
            "Resets every tab -- General, Appearance, History display, and Shortcuts -- back to its original defaults. History entries themselves aren't affected."
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
    }

    private weak var readingModeCheckbox: NSButton?
    private weak var linkClicksCheckbox: NSButton?
    private weak var formatCheckbox: NSButton?
    private weak var indentCheckbox: NSButton?
    private weak var newBookControl: NSSegmentedControl?

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshReadingModeCheckbox()
        linkClicksCheckbox?.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
    }

    private func refreshReadingModeCheckbox() {
        guard let vc = frontmostReaderVC() else {
            readingModeCheckbox?.state = .off
            readingModeCheckbox?.isEnabled = false
            return
        }
        readingModeCheckbox?.isEnabled = true
        readingModeCheckbox?.state = vc.currentMode == .paginated ? .on : .off
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
        // call returns. The checkbox's own just-set state is what the user
        // intended and is correct here without waiting on that round-trip.
        vc.toggleReadingMode(nil)
    }

    @objc private func toggleFormatForAO3(_ sender: NSButton) {
        // SettingsManager still stores this as "formatFirstChapter" internally;
        // EPUBParser's behaviour is now global (not first-chapter-only) — see EPUBParser.
        SettingsManager.shared.formatFirstChapter = sender.state == .on
    }

    @objc private func toggleRemoveParagraphIndents(_ sender: NSButton) {
        SettingsManager.shared.removeParagraphIndents = sender.state == .on
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
        alert.informativeText = "This resets General, Appearance, History display, and Shortcuts back to their original defaults. History entries themselves aren't affected. This can't be undone."
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
        formatCheckbox?.state = SettingsManager.shared.formatFirstChapter ? .on : .off
        indentCheckbox?.state = SettingsManager.shared.removeParagraphIndents ? .on : .off
        linkClicksCheckbox?.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
        newBookControl?.selectedSegment = SettingsManager.shared.newBookOpensIn.rawValue
        refreshReadingModeCheckbox()
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
//  • Selecting "Custom…" in the font popup revealed the free-text field but
//    never opened NSFontPanel, even though that's the more discoverable path
//    for most people. Now opens the panel immediately on selection, in
//    addition to the manual "Choose Font…" button for reopening it later.
//  • Theme selection was a plain NSPopUpButton plus a separate row of tiny
//    circular preset swatches, then later a fixed 2x3 grid of System/Light/
//    Dark/Sepia/Custom with only .custom actually editable. Now every theme
//    is a fully user-editable object (name + light/dark color pairs): the
//    grid wraps to fill the panel's full width, a "+" tile adds new themes,
//    and each swatch's own context menu handles rename/recolor/duplicate/
//    delete -- see Theme/ThemeColorSet in SettingsManager.swift.

final class AppearanceSettingsViewController: NSViewController, SettingsPaneSizing {

    var preferredPaneSize: NSSize?
    let isResizableView = false

    private var fontPopup: NSPopUpButton!
    private var fontFamilyField: NSTextField!   // free-form CSS font-family stack entry
    private var fontPickerButton: NSButton!     // opens NSFontPanel (replaces import button)
    private var themeGridContainer: NSStackView!  // vertical stack of full-width rows, wrapping
    private var themeButtons: [UUID: ThemeBigSwatchButton] = [:]
    /// Only one theme's inline editor is expanded at a time; selecting a
    /// different swatch collapses whichever one was previously expanded.
    /// Starts on the currently active theme so its editor is already open
    /// when the tab first appears, matching the swatch that's already shown
    /// selected.
    private var expandedThemeID: UUID? = SettingsManager.shared.currentThemeID
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
    private var fontFamilyFieldRow: NSGridRow!
    private var fontPickerButtonRow: NSGridRow!

    /// The currently previewed font name when the NSFontPanel is used
    private var pickedFontName: String = SettingsManager.shared.customFontName

    /// Index of the synthetic "Custom…" item, appended after all presets.
    private var customFontPopupIndex: Int { FontPresets.all.count }

    /// 16px is the reader WKWebView's unstyled base root font size; --reader-font-size
    /// is applied to <html> as a CSS percentage of that. See EPUBParser.readerVarsCSS.
    private static let baseFontSizePx: Double = 16

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size))

        // ── Form grid ────────────────────────────────────────────────────────
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        // Appearance mode -- overrides the system's light/dark setting for
        // the whole app (window chrome plus whichever of each theme's two
        // ThemeColorSets is in effect). "System" just tracks the OS, same as
        // before this control existed.
        grid.addRow(with: [label("Appearance:"), makeAppearanceModeControl()])

        // Themes first, no header — the grid is the section, stretched to fill
        // the panel's full width (see makeThemeGrid). Every swatch is directly
        // editable now (right-click, or double-click, for rename/recolor/
        // duplicate/delete), so there's no separate "Custom" case or presets
        // list living below it the way there used to be.
        let themeGridRow = grid.addRow(with: [makeThemeGrid(), NSGridCell.emptyContentView])
        themeGridRow.mergeCells(in: NSRange(location: 0, length: 2))
        themeGridRow.cell(at: 0).xPlacement = .fill

        // Typography, no header.
        grid.addRow(with: [label("Font:"), makeFontPopup()])
        fontFamilyFieldRow = grid.addRow(with: [NSGridCell.emptyContentView, makeFontFamilyField()])
        fontPickerButtonRow = grid.addRow(with: [NSGridCell.emptyContentView, makeFontPickerButton()])
        grid.addRow(with: [label("Font Size:"), makeFontSizeRow()])
        grid.addRow(with: [label("Line Height:"), makeLineHeightRow()])

        // Layout, no header.
        grid.addRow(with: [label("Max Width:"), makeMaxWidthRow()])
        grid.addRow(with: [label("Horizontal Margin:"), makePaddingHRow()])
        grid.addRow(with: [label("Vertical Margin:"), makePaddingVRow()])

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

        previewLabel = NSTextField(wrappingLabelWithString:
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
        // Appearance's real content (theme grid + typography + preview) is taller
        // than the shared pane height (SettingsPaneMetrics.size, same for every
        // tab now), especially with many themes -- the internal NSScrollView
        // handles
        // whatever doesn't fit.
        resolvePreferredPaneSize()

        updateCustomModeVisibility()
        refreshThemeGridSelection()
        refreshPreview()
    }

    /// Belt-and-suspenders on top of `clipContainer` being flipped: also
    /// explicitly scroll to top every time this tab appears, so re-opening
    /// Settings after switching tabs or resizing the window doesn't leave a
    /// stale scroll position either.
    override func viewWillAppear() {
        super.viewWillAppear()
        scrollView?.contentView.scroll(to: .zero)
        scrollView?.reflectScrolledClipView(scrollView.contentView)

        // The active theme can change elsewhere (the toolbar's theme popover)
        // while this tab isn't visible; re-sync so the expanded editor and
        // typography controls always match whatever's actually selected
        // rather than whatever was selected the last time this tab appeared.
        if expandedThemeID != SettingsManager.shared.currentThemeID {
            expandedThemeID = SettingsManager.shared.currentThemeID
            refreshAllTypographyControls()
            rebuildThemeGrid()
            refreshPreview()
        }
    }

    // MARK: - Control Factories

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func makeAppearanceModeControl() -> NSSegmentedControl {
        let modes = AppearanceMode.allCases
        let control = NSSegmentedControl(
            labels: modes.map(\.displayName),
            trackingMode: .selectOne,
            target: self,
            action: #selector(appearanceModeChanged(_:))
        )
        control.selectedSegment = modes.firstIndex(of: SettingsManager.shared.appearanceMode) ?? 0
        control.setAccessibilityLabel("Appearance")
        return control
    }

    @objc private func appearanceModeChanged(_ sender: NSSegmentedControl) {
        let modes = AppearanceMode.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
        SettingsManager.shared.appearanceMode = modes[sender.selectedSegment]
        // The bottom preview box is keyed off effective light/dark, which
        // just changed. The theme grid swatches above always render each
        // theme's own *light* colors regardless of appearance mode (see
        // ThemeBigSwatchButton.swatchImage), so they don't need a rebuild.
        refreshPreview()
    }

    private func makeFontPopup() -> NSPopUpButton {
        fontPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        fontPopup.addItems(withTitles: FontPresets.all.map { $0.label } + ["Custom…"])
        selectFontPopupItem(forCurrentFontFamily: SettingsManager.shared.fontFamily)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        return fontPopup
    }

    private func makeFontFamilyField() -> NSTextField {
        let field = NSTextField(string: SettingsManager.shared.fontFamily)
        field.target = self
        field.action = #selector(fontFamilyFieldChanged(_:))
        field.placeholderString = "e.g. Georgia, serif"
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        fontFamilyField = field
        return field
    }

    private func makeFontPickerButton() -> NSButton {
        let button = NSButton(
            title: pickedFontName.isEmpty ? "Choose Font…" : pickedFontName,
            target: self,
            action: #selector(openFontPanel(_:))
        )
        button.bezelStyle = .rounded
        fontPickerButton = button
        return button
    }

    private func selectFontPopupItem(forCurrentFontFamily family: String) {
        if let idx = FontPresets.all.firstIndex(where: { $0.cssStack == family }) {
            fontPopup.selectItem(at: idx)
        } else {
            fontPopup.selectItem(at: customFontPopupIndex)
        }
    }

    /// Every theme is directly editable now, so there's one grid, not a fixed
    /// 5-case grid plus a separate presets row underneath. Rows wrap at 4 items
    /// (themes + the trailing "+" tile) and each row uses .fillEqually so the
    /// whole thing stretches to the panel's full width, per the Apple Books
    /// reference. Rebuilt from scratch on any add/rename/duplicate/delete since
    /// the item count itself can change, not just individual swatch contents.
    private func makeThemeGrid() -> NSStackView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        themeGridContainer = container
        rebuildThemeGrid()
        return container
    }

    private func rebuildThemeGrid() {
        guard let container = themeGridContainer else { return }
        for v in container.arrangedSubviews { container.removeArrangedSubview(v); v.removeFromSuperview() }
        themeButtons.removeAll()

        let themes = SettingsManager.shared.themes
        // Clicking a swatch now expands its editor inline (see
        // themeSwatchClicked), so the context menu no longer needs a separate
        // rename entry -- Duplicate/Delete are the only actions that don't
        // already have a home in the expanded panel.
        let swatchCells: [NSView] = themes.map { theme in
            let button = ThemeBigSwatchButton(theme: theme)
            button.target = self
            button.action = #selector(themeSwatchClicked(_:))
            let menu = NSMenu()
            menu.addItem(withTitle: "Duplicate", action: #selector(duplicateThemeMenuAction(_:)), keyEquivalent: "")
            if !theme.isDefault && themes.count > 1 {
                menu.addItem(withTitle: "Delete", action: #selector(deleteThemeMenuAction(_:)), keyEquivalent: "")
            }
            for item in menu.items { item.target = self; item.representedObject = theme.id }
            button.menu = menu
            themeButtons[theme.id] = button
            return button
        }

        let perRow = 4
        // Row layout for the swatches: the "+" tile always joins the last
        // swatch row if there's room, so it visually sits right after the
        // themes. Only when the theme count exactly fills a row (4, 8, ...)
        // does it need a row of its own -- and even then that row must be
        // rendered immediately after the swatch row, before that row's
        // expanded color editor (if any), not after it. Previously the add
        // tile and the swatches were chunked together into one `cells` array,
        // which pushed the tile's own row below the editor in that case.
        func makeRow(_ views: [NSView]) {
            var rowCells = views
            // Pad a short row with invisible spacers so .fillEqually can't
            // stretch its real cells (including the add tile) wider than the
            // swatches in the full rows above -- otherwise the add tile ends
            // up a different size whenever it doesn't land in a full row.
            while rowCells.count < perRow {
                let spacer = NSView()
                spacer.heightAnchor.constraint(equalToConstant: ThemeBigSwatchButton.swatchSize.height).isActive = true
                rowCells.append(spacer)
            }
            let row = NSStackView(views: rowCells)
            row.orientation = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        for start in stride(from: 0, to: swatchCells.count, by: perRow) {
            let end = min(start + perRow, swatchCells.count)
            var rowCells = Array(swatchCells[start..<end])
            let isLastSwatchRow = end == swatchCells.count
            let addTileJoinsThisRow = isLastSwatchRow && rowCells.count < perRow
            if addTileJoinsThisRow {
                rowCells.append(makeAddThemeTile())
            }
            makeRow(rowCells)

            if isLastSwatchRow && !addTileJoinsThisRow {
                // Row filled exactly -- give the add tile its own row here,
                // still ahead of any expanded editor below.
                makeRow([makeAddThemeTile()])
            }

            // Which (if any) expanded theme belongs in this row, so its editor
            // panel can be inserted directly beneath it -- after the add tile
            // if the add tile belongs to this same row.
            let rowThemes = themes[start..<end]
            if let theme = rowThemes.first(where: { $0.id == expandedThemeID }) {
                let editor = makeInlineThemeEditor(for: theme)
                container.addArrangedSubview(editor)
                editor.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            }
        }
        if swatchCells.isEmpty {
            makeRow([makeAddThemeTile()])
        }
        refreshThemeGridSelection()
    }

    /// Grey-outlined tile matching the swatches' height, with a small centered
    /// plus icon -- not scaled up to fill the button, just its natural size.
    ///
    /// The outer button frame is pinned to the same height as
    /// ThemeBigSwatchButton, but the *visible* border can't just cover that
    /// whole frame: ThemeBigSwatchButton.swatchImage draws its rounded-rect
    /// only `size.height - 22` tall, inset from the top/bottom of the image,
    /// to leave room below for the theme name label. This tile has no label,
    /// so its border box mirrors that same inset (`box` below) rather than
    /// the full button bounds -- otherwise it reads as visibly taller than
    /// the swatches sitting next to it in the grid.
    private func makeAddThemeTile() -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(addThemeClicked(_:)))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.setAccessibilityLabel("Add a new theme")
        button.heightAnchor.constraint(equalToConstant: ThemeBigSwatchButton.swatchSize.height).isActive = true

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(box)

        let plus = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage())
        plus.contentTintColor = .secondaryLabelColor
        plus.translatesAutoresizingMaskIntoConstraints = false
        // Decorative: the enclosing button already carries the accessibility
        // label "Add a new theme" (see below), so exposing this glyph too would
        // have VoiceOver read the same thing twice.
        plus.setAccessibilityElement(false)
        box.addSubview(plus)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1),
            box.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            box.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -20),
            box.heightAnchor.constraint(equalToConstant: ThemeBigSwatchButton.swatchSize.height - 22),

            plus.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])

        return button
    }

    /// Line height is a unitless CSS multiplier (e.g. 1.6), not a pixel value --
    /// shown as a stepper with a one-decimal label, same visual language as the
    /// px steppers below, replacing the old bare slider with no visible value.
    private func makeLineHeightRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let s = NSStepper()
        s.minValue = 1.0
        s.maxValue = 3.0
        s.increment = 0.1
        s.doubleValue = SettingsManager.shared.lineHeight
        s.target = self
        s.action = #selector(lineHeightStepperChanged(_:))
        s.setAccessibilityLabel("Line Height")
        s.setAccessibilityValueDescription(String(format: "%.1f", SettingsManager.shared.lineHeight))
        lineHeightStepper = s

        let l = NSTextField(labelWithString: String(format: "%.1f", SettingsManager.shared.lineHeight))
        l.font = NSFont.systemFont(ofSize: 13)
        lineHeightLabel = l

        row.addArrangedSubview(s)
        row.addArrangedSubview(l)
        return row
    }

    /// Single parameterized factory for the remaining integer px steppers
    /// (max width / h margin / v margin). Font size has its own row below
    /// since it displays px while storing percent underneath.
    private func makeStepperRow(
        label accessibilityName: String,
        min: Double, max: Double, increment: Double,
        initialValue: Int,
        action: Selector,
        stepper: inout NSStepper!, valueLabel: inout NSTextField!
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let s = NSStepper()
        s.minValue = min
        s.maxValue = max
        s.increment = increment
        s.integerValue = initialValue
        s.target = self
        s.action = action
        s.setAccessibilityLabel(accessibilityName)
        s.setAccessibilityValueDescription("\(initialValue) pixels")
        stepper = s

        let l = NSTextField(labelWithString: "\(initialValue)px")
        l.font = NSFont.systemFont(ofSize: 13)
        valueLabel = l

        row.addArrangedSubview(s)
        row.addArrangedSubview(l)
        return row
    }

    /// Displays and edits the reader's root font size as an actual pixel
    /// number rather than a percentage -- see baseFontSizePx's doc comment.
    private func makeFontSizeRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let currentPx = Self.px(fromPercent: SettingsManager.shared.fontSizePercent)
        let s = NSStepper()
        s.minValue = Double(Self.px(fromPercent: 50))    // matches fontSizePercent's stored clamp (50-300%)
        s.maxValue = Double(Self.px(fromPercent: 300))
        s.increment = 1
        s.integerValue = currentPx
        s.target = self
        s.action = #selector(fontSizeStepperChanged(_:))
        s.setAccessibilityLabel("Font Size")
        s.setAccessibilityValueDescription("\(currentPx) pixels")
        fontSizeStepper = s

        let l = NSTextField(labelWithString: "\(currentPx)px")
        l.font = NSFont.systemFont(ofSize: 13)
        fontSizeLabel = l

        row.addArrangedSubview(s)
        row.addArrangedSubview(l)
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

    private func updateCustomModeVisibility() {
        let isCustomFont = !FontPresets.all.contains { $0.cssStack == SettingsManager.shared.fontFamily }
        fontFamilyFieldRow.isHidden = !isCustomFont
        fontPickerButtonRow.isHidden = !isCustomFont
    }

    private func refreshThemeGridSelection() {
        let current = SettingsManager.shared.currentThemeID
        for (id, button) in themeButtons {
            button.setSelected(id == current)
        }
    }

    /// Renders the current theme/font-size/line-height combination against
    /// real sample text so the effect of a change is visible without leaving
    /// Settings. Best-effort on the font: fontFamily is a CSS stack (e.g.
    /// "Georgia, serif"), not directly usable as an NSFont name, so this takes
    /// the first family name in the stack and falls back to the system font if
    /// AppKit doesn't have a font by that name -- exact CSS font resolution is
    /// WebKit's job when actually rendering the book.
    private func refreshPreview() {
        let colors = SettingsManager.shared.effectiveColorSet
        previewBox.fillColor = SettingsManager.color(fromCSS: colors.background)
        previewLabel.textColor = SettingsManager.color(fromCSS: colors.text)

        let px = Self.px(fromPercent: SettingsManager.shared.fontSizePercent)
        let firstFamily = SettingsManager.shared.fontFamily
            .split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? ""
        let previewFont = NSFont(name: firstFamily, size: CGFloat(px))
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

    /// Re-renders the current theme's own swatch thumbnail in place. Font
    /// changes (popup, free-form field, NSFontPanel) mutate currentTheme via
    /// SettingsManager but, unlike the color wells and name field, weren't
    /// nudging the swatch grid at all -- the "Aa" thumbnail kept showing the
    /// old font until something else (e.g. clicking a theme swatch) rebuilt
    /// the grid from fresh data.
    private func refreshCurrentThemeSwatch() {
        let theme = SettingsManager.shared.currentTheme
        themeButtons[theme.id]?.refresh(with: theme)
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx < FontPresets.all.count {
            SettingsManager.shared.fontFamily = FontPresets.all[idx].cssStack
            updateCustomModeVisibility()
            refreshPreview()
            refreshCurrentThemeSwatch()
        } else {
            // "Custom…" selected -- reveal the free-form field and open the
            // font panel immediately, since that's the more discoverable path
            // for most people; the "Choose Font…" button remains for
            // reopening the panel later without re-selecting the popup item.
            fontFamilyField.stringValue = SettingsManager.shared.fontFamily
            updateCustomModeVisibility()
            refreshPreview()
            openFontPanel(sender)
        }
    }

    @objc private func fontFamilyFieldChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        SettingsManager.shared.fontFamily = value
        refreshPreview()
        refreshCurrentThemeSwatch()
    }

    @objc private func openFontPanel(_ sender: Any?) {
        // Without this, changeFont(_:) depends on this view controller being
        // reachable via the responder chain at the moment a font is picked --
        // which it usually isn't here, since nothing in this tab holds first
        // responder and the panel itself takes key-window status from
        // Settings the moment it opens. Setting the target directly makes
        // delivery unconditional.
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))

        let panel = NSFontPanel.shared
        panel.worksWhenModal = true
        if !pickedFontName.isEmpty,
           let nsFont = NSFont(name: pickedFontName, size: NSFont.systemFontSize) {
            panel.setPanelFont(nsFont, isMultiple: false)
        }
        panel.makeKeyAndOrderFront(sender)
    }

    /// Responder-chain callback from NSFontPanel when user clicks a font.
    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }
        let currentFont = NSFont(name: pickedFontName, size: NSFont.systemFontSize)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let newFont = fontManager.convert(currentFont)
        let psName = newFont.fontName
        pickedFontName = psName
        SettingsManager.shared.customFontName = psName
        SettingsManager.shared.fontFamily = "'\(psName)', sans-serif"
        fontPickerButton.title = newFont.displayName ?? psName
        fontFamilyField.stringValue = SettingsManager.shared.fontFamily
        selectFontPopupItem(forCurrentFontFamily: SettingsManager.shared.fontFamily)
        updateCustomModeVisibility()
        refreshPreview()
        refreshCurrentThemeSwatch()
    }

    @objc private func themeSwatchClicked(_ sender: ThemeBigSwatchButton) {
        SettingsManager.shared.currentThemeID = sender.theme.id
        expandedThemeID = sender.theme.id
        refreshAllTypographyControls()
        rebuildThemeGrid()
        refreshPreview()
    }

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
        expandedThemeID = SettingsManager.shared.currentThemeID
        refreshAllTypographyControls()
        rebuildThemeGrid()
        refreshPreview()
    }

    /// Re-reads every typography control (font popup/field, line height,
    /// font size, margins) from SettingsManager -- needed both after Reset to
    /// Defaults and after switching the active theme, since typography is now
    /// per-theme (see Theme.fontFamily's doc comment) rather than one global
    /// setting shared across every theme.
    private func refreshAllTypographyControls() {
        selectFontPopupItem(forCurrentFontFamily: SettingsManager.shared.fontFamily)
        fontFamilyField.stringValue = SettingsManager.shared.fontFamily
        refreshThemeGridSelection()
        lineHeightStepper.doubleValue = SettingsManager.shared.lineHeight
        lineHeightLabel.stringValue = String(format: "%.1f", SettingsManager.shared.lineHeight)
        let px = Self.px(fromPercent: SettingsManager.shared.fontSizePercent)
        fontSizeStepper.integerValue = px
        fontSizeLabel.stringValue = "\(px)px"
        maxWidthStepper.integerValue = SettingsManager.shared.maxWidth
        maxWidthLabel.stringValue = "\(SettingsManager.shared.maxWidth)px"
        paddingHStepper.integerValue = SettingsManager.shared.paddingH
        paddingHLabel.stringValue = "\(SettingsManager.shared.paddingH)px"
        paddingVStepper.integerValue = SettingsManager.shared.paddingV
        paddingVLabel.stringValue = "\(SettingsManager.shared.paddingV)px"
        updateCustomModeVisibility()
    }

    // MARK: - Theme add / edit / duplicate / delete

    @objc private func addThemeClicked(_ sender: Any?) {
        let base = SettingsManager.shared.themes.first
        let light = base?.light ?? ThemeColorSet(background: "#ffffff", text: "#000000", link: "#0068da")
        let dark = base?.dark ?? ThemeColorSet(background: "#1c1c1e", text: "#e8e0d4", link: "#5aa9ff")
        let existingNames = Set(SettingsManager.shared.themes.map(\.name))
        var name = "New Theme"
        var suffix = 2
        while existingNames.contains(name) {
            name = "New Theme \(suffix)"
            suffix += 1
        }
        var newTheme = Theme(name: name, light: light, dark: dark)
        if let base {
            newTheme.fontFamily = base.fontFamily
            newTheme.fontSizePercent = base.fontSizePercent
            newTheme.lineHeight = base.lineHeight
            newTheme.maxWidth = base.maxWidth
            newTheme.paddingH = base.paddingH
            newTheme.paddingV = base.paddingV
        }
        SettingsManager.shared.addTheme(newTheme)
        expandedThemeID = newTheme.id
        refreshAllTypographyControls()
        rebuildThemeGrid()
        refreshPreview()
    }

    @objc private func duplicateThemeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        duplicateTheme(id: id)
    }

    @objc private func deleteThemeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        deleteTheme(id: id)
    }

    private func duplicateTheme(id: UUID) {
        guard let original = SettingsManager.shared.themes.first(where: { $0.id == id }) else { return }
        var copy = Theme(name: original.name + " Copy", light: original.light, dark: original.dark)
        copy.fontFamily = original.fontFamily
        copy.fontSizePercent = original.fontSizePercent
        copy.lineHeight = original.lineHeight
        copy.maxWidth = original.maxWidth
        copy.paddingH = original.paddingH
        copy.paddingV = original.paddingV
        SettingsManager.shared.addTheme(copy)
        expandedThemeID = copy.id
        refreshAllTypographyControls()
        rebuildThemeGrid()
        refreshPreview()
    }

    private func deleteTheme(id: UUID) {
        SettingsManager.shared.deleteTheme(id)
        if expandedThemeID == id { expandedThemeID = SettingsManager.shared.currentThemeID }
        refreshAllTypographyControls()
        rebuildThemeGrid()
        refreshPreview()
    }

    /// Inline expanding editor shown directly beneath the selected swatch's
    /// row: a name field with Duplicate/Delete off to the side, then
    /// light/dark colors side by side so both are visible at once instead of
    /// switching between them in separate wells inside a sheet. All fields
    /// live-update the theme (name on every keystroke, colors on every pick)
    /// and re-render the swatch immediately.
    private func makeInlineThemeEditor(for theme: Theme) -> NSView {
        let outer = NSBox()
        outer.boxType = .custom
        outer.cornerRadius = 8
        outer.borderWidth = 1
        outer.borderColor = .separatorColor
        outer.fillColor = .controlBackgroundColor
        outer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false

        // ── Name + Duplicate/Delete ─────────────────────────────────────────
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10

        let nameLabel = NSTextField(labelWithString: "Name")
        let nameField = ThemeIdentifiedTextField(string: theme.name)
        nameField.themeID = theme.id
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        nameField.delegate = self

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let duplicateButton = ThemeIdentifiedButton(title: "Duplicate", target: self, action: #selector(duplicateThemeInlineClicked(_:)))
        duplicateButton.themeID = theme.id
        duplicateButton.bezelStyle = .rounded

        let deleteButton = ThemeIdentifiedButton(title: "Delete", target: self, action: #selector(deleteThemeInlineClicked(_:)))
        deleteButton.themeID = theme.id
        deleteButton.bezelStyle = .rounded
        deleteButton.contentTintColor = .systemRed
        deleteButton.isEnabled = !theme.isDefault && SettingsManager.shared.themes.count > 1

        topRow.addArrangedSubview(nameLabel)
        topRow.addArrangedSubview(nameField)
        topRow.addArrangedSubview(spacer)
        topRow.addArrangedSubview(duplicateButton)
        topRow.addArrangedSubview(deleteButton)
        content.addArrangedSubview(topRow)
        topRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        content.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        // ── Light / Dark colors, side by side ───────────────────────────────
        let colorsRow = NSStackView()
        colorsRow.orientation = .horizontal
        colorsRow.alignment = .top
        colorsRow.spacing = 32
        colorsRow.distribution = .fillEqually

        func colorColumn(title: String, colors: ThemeColorSet, isDark: Bool) -> NSView {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 8

            let header = NSTextField(labelWithString: title)
            header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            column.addArrangedSubview(header)

            func row(_ label: String, field: ThemeColorField, value: String) -> NSView {
                let r = NSStackView()
                r.orientation = .horizontal
                r.spacing = 8
                let l = NSTextField(labelWithString: label)
                l.widthAnchor.constraint(equalToConstant: 80).isActive = true
                let well = ThemeColorWell()
                well.themeID = theme.id
                well.field = field
                well.color = SettingsManager.color(fromCSS: value)
                well.target = self
                well.action = #selector(themeColorWellChanged(_:))
                r.addArrangedSubview(l)
                r.addArrangedSubview(well)
                return r
            }

            column.addArrangedSubview(row("Background", field: isDark ? .darkBackground : .lightBackground, value: colors.background))
            column.addArrangedSubview(row("Text", field: isDark ? .darkText : .lightText, value: colors.text))
            column.addArrangedSubview(row("Link", field: isDark ? .darkLink : .lightLink, value: colors.link))
            return column
        }

        colorsRow.addArrangedSubview(colorColumn(title: "Light", colors: theme.light, isDark: false))
        colorsRow.addArrangedSubview(colorColumn(title: "Dark", colors: theme.dark, isDark: true))
        content.addArrangedSubview(colorsRow)
        colorsRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        outer.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: outer.contentView!.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: outer.contentView!.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: outer.contentView!.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: outer.contentView!.bottomAnchor, constant: -14),
        ])

        return outer
    }

    @objc private func duplicateThemeInlineClicked(_ sender: ThemeIdentifiedButton) {
        guard let id = sender.themeID else { return }
        duplicateTheme(id: id)
    }

    @objc private func deleteThemeInlineClicked(_ sender: ThemeIdentifiedButton) {
        guard let id = sender.themeID else { return }
        deleteTheme(id: id)
    }

    @objc private func themeColorWellChanged(_ sender: ThemeColorWell) {
        guard let id = sender.themeID, let field = sender.field,
              var theme = SettingsManager.shared.themes.first(where: { $0.id == id })
        else { return }
        let hex = SettingsManager.cssHex(from: sender.color)
        switch field {
        case .lightBackground: theme.light.background = hex
        case .lightText: theme.light.text = hex
        case .lightLink: theme.light.link = hex
        case .darkBackground: theme.dark.background = hex
        case .darkText: theme.dark.text = hex
        case .darkLink: theme.dark.link = hex
        }
        SettingsManager.shared.updateTheme(theme)
        themeButtons[id]?.refresh(with: theme)
        refreshPreview()
    }
}

extension AppearanceSettingsViewController: NSTextFieldDelegate {
    /// Live-updates the theme name on every keystroke, same pattern as the
    /// color wells below -- not gated on Enter/commit.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? ThemeIdentifiedTextField, let id = field.themeID else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var theme = SettingsManager.shared.themes.first(where: { $0.id == id }) else { return }
        theme.name = name
        SettingsManager.shared.updateTheme(theme)
        themeButtons[id]?.refresh(with: theme)
    }
}

// MARK: - Inline theme editor field/control identity helpers
//
// NSButton/NSTextField/NSColorWell have no built-in representedObject the way
// NSMenuItem does, so these tiny subclasses carry the theme id (and, for
// color wells, which of the six color fields) that each control edits.

private enum ThemeColorField {
    case lightBackground, lightText, lightLink, darkBackground, darkText, darkLink
}

private final class ThemeColorWell: NSColorWell {
    var themeID: UUID?
    var field: ThemeColorField?
}

private final class ThemeIdentifiedButton: NSButton {
    var themeID: UUID?
}

private final class ThemeIdentifiedTextField: NSTextField {
    var themeID: UUID?
}

// MARK: - ThemeBigSwatchButton

/// A large Apple-Books-style theme swatch: "Aa" rendered in the theme's own
/// background/text colors, with the theme's name below. Used in the 2x3 theme
/// grid; selection is shown as an accent-colored ring.
final class ThemeBigSwatchButton: NSButton {
    private(set) var theme: Theme
    static let swatchSize = NSSize(width: 110, height: 84)

    private var isThemeSelected = false

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        image = Self.swatchImage(for: theme, selected: false)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel(theme.name)
        // No fixed-width constraint: the grid's .fillEqually rows stretch each
        // swatch to fill the panel's full width, so only height is pinned.
        heightAnchor.constraint(equalToConstant: Self.swatchSize.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        guard selected != isThemeSelected else { return }
        isThemeSelected = selected
        image = Self.swatchImage(for: theme, selected: selected)
        setAccessibilityValueDescription(selected ? "Selected" : nil)
    }

    /// Re-renders this swatch in place for a live name/color edit -- called
    /// from the inline theme editor on every change, same as the rename flow
    /// already did before the editor was inline.
    func refresh(with theme: Theme) {
        self.theme = theme
        image = Self.swatchImage(for: theme, selected: isThemeSelected)
        setAccessibilityLabel(theme.name)
    }

    /// Rendered against the swatch's own light colors and its own font — the
    /// grid's meant to show what each theme looks like on its own terms, not
    /// shift with the window's momentary system appearance while browsing the
    /// list, and not all show whichever theme happens to be currently active.
    /// Same best-effort CSS-stack-to-NSFont resolution as
    /// AppearanceSettingsViewController.refreshPreview: takes the first family
    /// name in the theme's own font stack and falls back to the system font
    /// if AppKit doesn't have a font by that name.
    private static func previewFont(for theme: Theme, ofSize size: CGFloat) -> NSFont {
        let firstFamily = theme.fontFamily
            .split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? ""
        return NSFont(name: firstFamily, size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }

    private static func swatchImage(for theme: Theme, selected: Bool) -> NSImage {
        let size = swatchSize
        let image = NSImage(size: size)
        image.lockFocus()

        let bg = SettingsManager.color(fromCSS: theme.light.background)
        let text = SettingsManager.color(fromCSS: theme.light.text)

        let swatchRect = NSRect(x: 1, y: 20, width: size.width - 2, height: size.height - 22)
        let path = NSBezierPath(roundedRect: swatchRect, xRadius: 8, yRadius: 8)
        bg.setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2.5 : 1
        path.stroke()

        let aa = NSAttributedString(string: "Aa", attributes: [
            .font: Self.previewFont(for: theme, ofSize: 26),
            .foregroundColor: text,
        ])
        let aaSize = aa.size()
        aa.draw(at: NSPoint(x: swatchRect.midX - aaSize.width / 2, y: swatchRect.midY - aaSize.height / 2))

        let name = NSAttributedString(string: theme.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
        let nameSize = name.size()
        name.draw(at: NSPoint(x: size.width / 2 - nameSize.width / 2, y: 2))

        image.unlockFocus()
        return image
    }
}

// MARK: - History Settings

final class HistorySettingsViewController: NSViewController, SettingsPaneSizing {

    var preferredPaneSize: NSSize?
    let isResizableView = false
    private var tableView: NSTableView!

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
            clearBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
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
    }

    @objc private func reload() { tableView.reloadData() }

    @objc private func clearHistory(_ sender: Any?) {
        HistoryManager.shared.clearAll()
        tableView.reloadData()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

extension HistorySettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        HistoryManager.shared.entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = HistoryManager.shared.entries[row]
        let cell = HistorySettingsCellView()
        cell.configure(with: entry)
        return cell
    }
}

final class HistorySettingsCellView: NSTableCellView {
    private let titleLabel  = NSTextField(labelWithString: "")
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
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(with entry: HistoryEntry) {
        titleLabel.stringValue = entry.title.isEmpty
            ? entry.url.deletingPathExtension().lastPathComponent
            : entry.title

        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        let dateStr = fmt.localizedString(for: entry.openedAt, relativeTo: Date())
        let pctStr  = entry.readingProgressPercent > 0 ? "\(entry.readingProgressPercent)% read" : "Not started"
        detailLabel.stringValue = "\(dateStr) • \(pctStr)"
    }
}

// MARK: - CustomFontStore
// Retained for backwards-compatibility with persisted custom font names.
// No longer populated via file import; NSFontPanel writes directly to SettingsManager.customFontName.

struct CustomFont: Codable {
    let id: UUID
    let name: String        // PostScript name
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
              let decoded = try? JSONDecoder().decode([CustomFont].self, from: data) else { return }
        fonts = decoded
        // Re-register any previously imported font files with Core Text
        for font in fonts {
            let url = storageDir.appendingPathComponent(font.filename)
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
