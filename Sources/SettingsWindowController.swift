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

import AppKit
import UniformTypeIdentifiers

// MARK: - Window Controller

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        NSLog("[Honeycrisp][Settings] SettingsWindowController.init start")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.maxSize = NSSize(width: 720, height: 900)
        super.init(window: window)
        NSLog("[Honeycrisp][Settings] SettingsWindowController.init: window created, assigning contentViewController")
        window.contentViewController = SettingsTabViewController()
        NSLog("[Honeycrisp][Settings] SettingsWindowController.init done")
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Tab View Controller

final class SettingsTabViewController: NSTabViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("[Honeycrisp][Settings] SettingsTabViewController.viewDidLoad start")

        // Typography tab intentionally removed.
        let tabSpecs: [(() -> NSViewController, String, String)] = [
            ({ GeneralSettingsViewController() },    "General",    "gear"),
            ({ AppearanceSettingsViewController() }, "Appearance", "paintbrush"),
            ({ HistorySettingsViewController() },    "History",    "clock"),
            ({ ShortcutsSettingsViewController() },  "Shortcuts",  "keyboard"),
        ]

        for (makeVC, label, symbol) in tabSpecs {
            NSLog("[Honeycrisp][Settings] constructing tab: %@", label)
            let vc = makeVC()
            NSLog("[Honeycrisp][Settings] constructed tab: %@, adding NSTabViewItem", label)
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            addTabViewItem(item)
            NSLog("[Honeycrisp][Settings] added tab: %@", label)
        }
        NSLog("[Honeycrisp][Settings] SettingsTabViewController.viewDidLoad done, tabViewItems.count=%d", tabViewItems.count)
    }
}

// MARK: - General Settings

final class GeneralSettingsViewController: NSViewController {

    override func loadView() {
        NSLog("[Honeycrisp][Settings] GeneralSettingsViewController.loadView start")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // "Format for AO3" (renamed from "Format first chapter")
        let formatCheckbox = NSButton(
            checkboxWithTitle: "Format for AO3",
            target: self,
            action: #selector(toggleFormatForAO3(_:))
        )
        formatCheckbox.state = SettingsManager.shared.formatFirstChapter ? .on : .off
        stack.addArrangedSubview(formatCheckbox)

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

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)
        ])

        self.view = root
        NSLog("[Honeycrisp][Settings] GeneralSettingsViewController.loadView done")
    }

    private weak var readingModeCheckbox: NSButton?

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshReadingModeCheckbox()
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

    /// Same lookup AppDelegate.readerVC() uses for the View-menu toggle. The
    /// Settings window is a separate NSWindow, so NSApp.keyWindow at the moment
    /// this fires is Settings itself, not the reader — mainWindow (the app's
    /// most-recently-main document window) is the right lookup here instead.
    private func frontmostReaderVC() -> ReaderViewController? {
        NSApp.mainWindow?.contentViewController as? ReaderViewController
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

final class AppearanceSettingsViewController: NSViewController {

    private var fontPopup: NSPopUpButton!
    private var fontFamilyField: NSTextField!   // free-form CSS font-family stack entry
    private var fontPickerButton: NSButton!     // opens NSFontPanel (replaces import button)
    private var themeGridContainer: NSStackView!  // vertical stack of full-width rows, wrapping
    private var themeButtons: [UUID: ThemeBigSwatchButton] = [:]
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
    private var linkClicksCheckbox: NSButton!

    private var previewBox: NSBox!
    private var previewLabel: NSTextField!

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
        NSLog("[Honeycrisp][Settings] AppearanceSettingsViewController.loadView start")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 480))

        // ── Form grid ────────────────────────────────────────────────────────
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

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

        linkClicksCheckbox = NSButton(
            checkboxWithTitle: "Allow link clicks",
            target: self,
            action: #selector(linkClicksChanged(_:))
        )
        linkClicksCheckbox.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, linkClicksCheckbox])

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

        let clipContainer = NSView()
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

        updateCustomModeVisibility()
        refreshThemeGridSelection()
        refreshPreview()
        NSLog("[Honeycrisp][Settings] AppearanceSettingsViewController.loadView done")
    }

    // MARK: - Control Factories

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
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
        var cells: [NSView] = themes.map { theme in
            let button = ThemeBigSwatchButton(theme: theme)
            button.target = self
            button.action = #selector(themeSwatchClicked(_:))
            let menu = NSMenu()
            menu.addItem(withTitle: "Rename & Recolor…", action: #selector(editThemeMenuAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Duplicate", action: #selector(duplicateThemeMenuAction(_:)), keyEquivalent: "")
            if themes.count > 1 {
                menu.addItem(withTitle: "Delete", action: #selector(deleteThemeMenuAction(_:)), keyEquivalent: "")
            }
            for item in menu.items { item.target = self; item.representedObject = theme.id }
            button.menu = menu
            themeButtons[theme.id] = button
            return button
        }
        cells.append(makeAddThemeTile())

        let perRow = 4
        for start in stride(from: 0, to: cells.count, by: perRow) {
            let row = NSStackView(views: Array(cells[start..<min(start + perRow, cells.count)]))
            row.orientation = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        refreshThemeGridSelection()
    }

    private func makeAddThemeTile() -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(addThemeClicked(_:)))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add a new theme")
        button.imageScaling = .scaleProportionallyUpOrDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.cgColor
        button.setAccessibilityLabel("Add a new theme")
        button.heightAnchor.constraint(equalToConstant: ThemeBigSwatchButton.swatchSize.height).isActive = true
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

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx < FontPresets.all.count {
            SettingsManager.shared.fontFamily = FontPresets.all[idx].cssStack
            updateCustomModeVisibility()
            refreshPreview()
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
    }

    @objc private func openFontPanel(_ sender: Any?) {
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
    }

    @objc private func themeSwatchClicked(_ sender: ThemeBigSwatchButton) {
        SettingsManager.shared.currentThemeID = sender.theme.id
        refreshThemeGridSelection()
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

    @objc private func linkClicksChanged(_ sender: NSButton) {
        SettingsManager.shared.allowReaderLinkClicks = sender.state == .on
    }

    @objc private func resetToDefaults(_ sender: NSButton) {
        SettingsManager.shared.resetReaderToDefaults()

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
        linkClicksCheckbox.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
        updateCustomModeVisibility()
        refreshPreview()
    }

    // MARK: - Theme add / edit / duplicate / delete

    @objc private func addThemeClicked(_ sender: Any?) {
        let base = SettingsManager.shared.themes.first
        let light = base?.light ?? ThemeColorSet(background: "#ffffff", text: "#000000", link: "#0068da")
        let dark = base?.dark ?? ThemeColorSet(background: "#1c1c1e", text: "#e8e0d4", link: "#5aa9ff")
        var newTheme = Theme(name: "New Theme", light: light, dark: dark)
        if presentThemeEditor(for: &newTheme, title: "Add Theme") {
            SettingsManager.shared.addTheme(newTheme)
            rebuildThemeGrid()
            refreshPreview()
        }
    }

    @objc private func editThemeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              var theme = SettingsManager.shared.themes.first(where: { $0.id == id })
        else { return }
        if presentThemeEditor(for: &theme, title: "Edit Theme") {
            SettingsManager.shared.updateTheme(theme)
            rebuildThemeGrid()
            refreshPreview()
        }
    }

    @objc private func duplicateThemeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let original = SettingsManager.shared.themes.first(where: { $0.id == id })
        else { return }
        var copy = Theme(name: original.name + " Copy", light: original.light, dark: original.dark)
        if presentThemeEditor(for: &copy, title: "Duplicate Theme") {
            SettingsManager.shared.addTheme(copy)
            rebuildThemeGrid()
            refreshPreview()
        }
    }

    @objc private func deleteThemeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        SettingsManager.shared.deleteTheme(id)
        rebuildThemeGrid()
        refreshPreview()
    }

    /// Sheet-style NSAlert (same pattern the old "Save as Preset…" alert used)
    /// with a name field and six color wells: light/dark x background/text/
    /// link. Mutates `theme` in place and returns whether Save was clicked.
    @discardableResult
    private func presentThemeEditor(for theme: inout Theme, title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let nameField = NSTextField(string: theme.name)
        nameField.placeholderString = "Theme name"
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        container.addArrangedSubview(nameField)

        func colorRow(_ label: String, _ initial: String) -> (NSStackView, NSColorWell) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let l = NSTextField(labelWithString: label)
            l.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let well = NSColorWell()
            well.color = SettingsManager.color(fromCSS: initial)
            row.addArrangedSubview(l)
            row.addArrangedSubview(well)
            return (row, well)
        }

        let (lightBgRow, lightBgWell) = colorRow("Light Background:", theme.light.background)
        let (lightTextRow, lightTextWell) = colorRow("Light Text:", theme.light.text)
        let (lightLinkRow, lightLinkWell) = colorRow("Light Links:", theme.light.link)
        let (darkBgRow, darkBgWell) = colorRow("Dark Background:", theme.dark.background)
        let (darkTextRow, darkTextWell) = colorRow("Dark Text:", theme.dark.text)
        let (darkLinkRow, darkLinkWell) = colorRow("Dark Links:", theme.dark.link)
        for row in [lightBgRow, lightTextRow, lightLinkRow, darkBgRow, darkTextRow, darkLinkRow] {
            container.addArrangedSubview(row)
        }

        alert.accessoryView = container
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { theme.name = name }
        theme.light = ThemeColorSet(
            background: SettingsManager.cssHex(from: lightBgWell.color),
            text: SettingsManager.cssHex(from: lightTextWell.color),
            link: SettingsManager.cssHex(from: lightLinkWell.color)
        )
        theme.dark = ThemeColorSet(
            background: SettingsManager.cssHex(from: darkBgWell.color),
            text: SettingsManager.cssHex(from: darkTextWell.color),
            link: SettingsManager.cssHex(from: darkLinkWell.color)
        )
        return true
    }
}

// MARK: - ThemeBigSwatchButton

/// A large Apple-Books-style theme swatch: "Aa" rendered in the theme's own
/// background/text colors, with the theme's name below. Used in the 2x3 theme
/// grid; selection is shown as an accent-colored ring.
final class ThemeBigSwatchButton: NSButton {
    let theme: Theme
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

    /// Rendered against the swatch's own light colors — the grid's meant to
    /// show what each theme looks like on its own terms, not shift with the
    /// window's momentary system appearance while browsing the list.
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
            .font: NSFont.systemFont(ofSize: 26, weight: .medium),
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

final class HistorySettingsViewController: NSViewController {
    private var tableView: NSTableView!

    override func loadView() {
        NSLog("[Honeycrisp][Settings] HistorySettingsViewController.loadView start")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

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
        col.width = 440
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
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: clearBtn.topAnchor, constant: -10),

            clearBtn.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            clearBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        self.view = root

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: SettingsManager.settingsChangedNotification, object: nil
        )
        NSLog("[Honeycrisp][Settings] HistorySettingsViewController.loadView done")
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
