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
//    circular preset swatches. Replaced with a 2-column x 3-row grid of large
//    Apple-Books-style swatches -- "Aa" rendered in the theme's own colors
//    plus its name -- for the 5 ReaderTheme cases (System/Light/Dark/Sepia/
//    Custom), with a 6th "+" cell to save the current custom colors as a new
//    named preset. The smaller circular-swatch preset picker and color wells
//    remain, now living directly under the grid and shown only when Custom is
//    the active theme, since the grid only has room for one "Custom" slot but
//    someone may have saved several presets.

final class AppearanceSettingsViewController: NSViewController {

    private var fontPopup: NSPopUpButton!
    private var fontFamilyField: NSTextField!   // free-form CSS font-family stack entry
    private var fontPickerButton: NSButton!     // opens NSFontPanel (replaces import button)
    private var themeGrid: NSGridView!
    private var themeButtons: [ReaderTheme: ThemeBigSwatchButton] = [:]
    private var bgColorWell: NSColorWell!
    private var textColorWell: NSColorWell!
    private var lineHeightStepper: NSStepper!
    private var lineHeightLabel: NSTextField!
    private var fontSizeStepper: NSStepper!
    private var fontSizeLabel: NSTextField!
    private var presetsRow: NSStackView!
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
    private var customColorsHeaderRow: NSGridRow!
    private var bgColorGridRow: NSGridRow!
    private var textColorGridRow: NSGridRow!
    private var presetsGridRow: NSGridRow!
    private var savePresetGridRow: NSGridRow!

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

        addSectionHeader("Typography", to: grid)
        grid.addRow(with: [label("Font:"), makeFontPopup()])
        fontFamilyFieldRow = grid.addRow(with: [NSGridCell.emptyContentView, makeFontFamilyField()])
        fontPickerButtonRow = grid.addRow(with: [NSGridCell.emptyContentView, makeFontPickerButton()])
        grid.addRow(with: [label("Font Size:"), makeFontSizeRow()])
        grid.addRow(with: [label("Line Height:"), makeLineHeightRow()])

        addSectionHeader("Theme", to: grid)
        let themeGridRow = grid.addRow(with: [makeThemeGrid(), NSGridCell.emptyContentView])
        themeGridRow.mergeCells(in: NSRange(location: 0, length: 2))

        customColorsHeaderRow = addSectionHeader("Custom Colors", to: grid)
        bgColorWell = makeColorWell(action: #selector(bgColorChanged(_:)))
        bgColorGridRow = grid.addRow(with: [label("Background:"), bgColorWell])
        textColorWell = makeColorWell(action: #selector(textColorChanged(_:)))
        textColorGridRow = grid.addRow(with: [label("Text Color:"), textColorWell])
        presetsRow = makePresetsRow()
        presetsGridRow = grid.addRow(with: [label("Saved Presets:"), presetsRow])
        let savePresetButton = NSButton(title: "Save as Preset…", target: self, action: #selector(saveAsPreset(_:)))
        savePresetButton.bezelStyle = .rounded
        savePresetGridRow = grid.addRow(with: [NSGridCell.emptyContentView, savePresetButton])

        addSectionHeader("Layout", to: grid)
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
        updateCustomColorSectionVisibility()
        refreshThemeGridSelection()
        refreshPreview()
        NSLog("[Honeycrisp][Settings] AppearanceSettingsViewController.loadView done")
    }

    // MARK: - Control Factories

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    @discardableResult
    private func addSectionHeader(_ title: String, to grid: NSGridView) -> NSGridRow {
        let header = NSTextField(labelWithString: title)
        header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let row = grid.addRow(with: [header, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.topPadding = grid.numberOfRows == 1 ? 0 : 14
        return row
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

    /// 2-column x 3-row grid of large theme swatches: the 5 ReaderTheme cases
    /// (System/Light/Dark/Sepia/Custom), each showing "Aa" in the theme's own
    /// colors plus its name, and a 6th "+" cell to save the current custom
    /// colors as a new named preset.
    private func makeThemeGrid() -> NSGridView {
        let tGrid = NSGridView(numberOfColumns: 2, rows: 0)
        tGrid.rowSpacing = 10
        tGrid.columnSpacing = 10
        tGrid.translatesAutoresizingMaskIntoConstraints = false

        let cells: [NSView] = ReaderTheme.allCases.map { theme in
            let button = ThemeBigSwatchButton(theme: theme)
            button.target = self
            button.action = #selector(themeSwatchClicked(_:))
            themeButtons[theme] = button
            return button
        } + [makeAddPresetSwatch()]

        for pair in stride(from: 0, to: cells.count, by: 2) {
            let right = pair + 1 < cells.count ? cells[pair + 1] : NSGridCell.emptyContentView
            tGrid.addRow(with: [cells[pair], right])
        }
        themeGrid = tGrid
        return tGrid
    }

    private func makeAddPresetSwatch() -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(saveAsPreset(_:)))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add theme preset")
        button.imageScaling = .scaleProportionallyUpOrDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.cgColor
        button.setAccessibilityLabel("Add a new theme preset")
        button.widthAnchor.constraint(equalToConstant: ThemeBigSwatchButton.swatchSize.width).isActive = true
        button.heightAnchor.constraint(equalToConstant: ThemeBigSwatchButton.swatchSize.height).isActive = true
        return button
    }

    private func makePresetsRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        rebuildPresetSwatches(in: row)
        return row
    }

    private func rebuildPresetSwatches(in row: NSStackView) {
        for v in row.arrangedSubviews { row.removeArrangedSubview(v); v.removeFromSuperview() }
        for preset in SettingsManager.shared.savedThemes {
            row.addArrangedSubview(makeSwatchButton(for: preset))
        }
    }

    private func makeSwatchButton(for preset: SavedTheme) -> NSView {
        let button = ThemeSwatchButton(preset: preset)
        button.target = self
        button.action = #selector(presetSwatchClicked(_:))
        button.onDelete = { [weak self] in self?.deletePreset(preset) }
        return button
    }

    private func makeColorWell(action: Selector) -> NSColorWell {
        let well = NSColorWell()
        well.target = self
        well.action = action
        return well
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
        s.minValue = Self.px(fromPercent: 50)    // matches fontSizePercent's stored clamp (50-300%)
        s.maxValue = Self.px(fromPercent: 300)
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

    /// The grid only has room for one "Custom" slot, but someone may have
    /// several saved presets -- this section (color wells + saved-preset
    /// swatches + save button) lives under the grid and is shown only while
    /// Custom is the active theme, where it's actually relevant.
    private func updateCustomColorSectionVisibility() {
        let isCustomTheme = SettingsManager.shared.currentTheme == .custom
        if let well = bgColorWell {
            well.color = SettingsManager.color(fromCSS: SettingsManager.shared.customBackgroundCSS)
        }
        if let well = textColorWell {
            well.color = SettingsManager.color(fromCSS: SettingsManager.shared.customTextCSS)
        }
        customColorsHeaderRow.isHidden = !isCustomTheme
        bgColorGridRow.isHidden = !isCustomTheme
        textColorGridRow.isHidden = !isCustomTheme
        presetsGridRow.isHidden = !isCustomTheme
        savePresetGridRow.isHidden = !isCustomTheme
    }

    private func refreshThemeGridSelection() {
        let current = SettingsManager.shared.currentTheme
        for (theme, button) in themeButtons {
            button.setSelected(theme == current)
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
        let theme = SettingsManager.shared.currentTheme
        if theme == .system {
            // cssBackground/cssText for .system are "transparent" and
            // "var(--system-text)" -- valid CSS the book's WebKit view resolves
            // itself, but not hex strings color(fromCSS:) can parse (it falls
            // back to black for non-hex input, which would render as an
            // unreadable black-on-black preview here).
            previewBox.fillColor = .windowBackgroundColor
            previewLabel.textColor = .labelColor
        } else {
            previewBox.fillColor = SettingsManager.color(fromCSS: theme.cssBackground)
            previewLabel.textColor = SettingsManager.color(fromCSS: theme.cssText)
        }

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
        SettingsManager.shared.currentTheme = sender.theme
        refreshThemeGridSelection()
        updateCustomColorSectionVisibility()
        refreshPreview()
    }

    @objc private func bgColorChanged(_ sender: NSColorWell) {
        SettingsManager.shared.customBackgroundCSS = SettingsManager.cssHex(from: sender.color)
        refreshPreview()
    }

    @objc private func textColorChanged(_ sender: NSColorWell) {
        SettingsManager.shared.customTextCSS = SettingsManager.cssHex(from: sender.color)
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
        updateCustomColorSectionVisibility()
        refreshPreview()
    }

    /// Prompts for a name via an NSAlert with an accessory text field and
    /// appends a SavedTheme built from the current custom colors. Reachable
    /// both from the grid's "+" cell and the "Save as Preset…" button under
    /// the color wells -- same action either way.
    @objc private func saveAsPreset(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Save Theme Preset"
        alert.informativeText = "Enter a name for this preset."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let preset = SavedTheme(
            name: name,
            backgroundCSS: SettingsManager.shared.customBackgroundCSS,
            textCSS: SettingsManager.shared.customTextCSS
        )
        SettingsManager.shared.savedThemes.append(preset)
        rebuildPresetSwatches(in: presetsRow)
    }

    @objc private func presetSwatchClicked(_ sender: ThemeSwatchButton) {
        SettingsManager.shared.currentTheme = .custom
        SettingsManager.shared.customBackgroundCSS = sender.preset.backgroundCSS
        SettingsManager.shared.customTextCSS = sender.preset.textCSS
        refreshThemeGridSelection()
        updateCustomColorSectionVisibility()
        refreshPreview()
    }

    private func deletePreset(_ preset: SavedTheme) {
        SettingsManager.shared.savedThemes.removeAll { $0.id == preset.id }
        rebuildPresetSwatches(in: presetsRow)
    }
}

// MARK: - ThemeBigSwatchButton

/// A large Apple-Books-style theme swatch: "Aa" rendered in the theme's own
/// background/text colors, with the theme's name below. Used in the 2x3 theme
/// grid; selection is shown as an accent-colored ring.
final class ThemeBigSwatchButton: NSButton {
    let theme: ReaderTheme
    static let swatchSize = NSSize(width: 110, height: 84)

    private var isThemeSelected = false

    init(theme: ReaderTheme) {
        self.theme = theme
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        image = Self.swatchImage(for: theme, selected: false)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel(theme.displayName)
        widthAnchor.constraint(equalToConstant: Self.swatchSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.swatchSize.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        guard selected != isThemeSelected else { return }
        isThemeSelected = selected
        image = Self.swatchImage(for: theme, selected: selected)
        setAccessibilityValueDescription(selected ? "Selected" : nil)
    }

    private static func swatchImage(for theme: ReaderTheme, selected: Bool) -> NSImage {
        let size = swatchSize
        let image = NSImage(size: size)
        image.lockFocus()

        let bg: NSColor = theme == .system ? .windowBackgroundColor : SettingsManager.color(fromCSS: theme.cssBackground)
        let text: NSColor = theme == .system ? .labelColor : SettingsManager.color(fromCSS: theme.cssText)

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

        let name = NSAttributedString(string: theme.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
        let nameSize = name.size()
        name.draw(at: NSPoint(x: size.width / 2 - nameSize.width / 2, y: 2))

        image.unlockFocus()
        return image
    }
}

// MARK: - ThemeSwatchButton

/// A small colored-circle-plus-name button representing one saved theme preset.
/// Right-click shows a "Delete" context menu — standard AppKit pattern, no sheet
/// needed for something this reversible.
final class ThemeSwatchButton: NSButton {
    let preset: SavedTheme
    var onDelete: (() -> Void)?

    init(preset: SavedTheme) {
        self.preset = preset
        super.init(frame: .zero)
        title = preset.name
        bezelStyle = .rounded
        image = Self.swatchImage(background: preset.backgroundCSS, text: preset.textCSS)
        imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelf), keyEquivalent: "")
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func deleteSelf() { onDelete?() }

    private static func swatchImage(background: String, text: String) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        let bg = SettingsManager.color(fromCSS: background)
        bg.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        let border = SettingsManager.color(fromCSS: text)
        border.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: 13, height: 13))
        path.lineWidth = 1
        path.stroke()
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
