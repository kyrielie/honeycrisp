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
// Rewritten to fix several issues found in review:
//  • The tab's content (18+ rows) was taller than the fixed, non-resizable
//    Settings window and was never wrapped in a scroll view -- most of it was
//    silently unreachable. Now wrapped in an NSScrollView (window is resizable
//    too, see SettingsWindowController.init).
//  • No live preview of the selected theme/font/colors existed. Added a fixed
//    preview strip at the top, refreshed from the same call sites that already
//    refresh color wells / labels.
//  • Rows were separate NSStackView label/control pairs, so label column widths
//    (and therefore where each control started) were inconsistent. Replaced
//    with a single NSGridView so every row's control aligns in one column, with
//    merged full-width rows as section headers (Typography / Colors / Layout).
//  • The font-picker button (opens NSFontPanel) was always visible regardless
//    of whether "Custom…" was selected. It's now hidden/shown alongside
//    fontFamilyField, since they're both only relevant in Custom mode.
//  • Stepper+label rows (font size, max width, h/v margin) were four
//    near-identical copy-pasted factory methods; consolidated into one
//    parameterized makeStepperRow(...).
//  • Added accessibility labels/value descriptions to the steppers so
//    VoiceOver announces units ("Font Size, 60 percent"), not just a bare
//    number read from an adjacent, unassociated text field.

final class AppearanceSettingsViewController: NSViewController {

    private var fontPopup: NSPopUpButton!
    private var fontFamilyField: NSTextField!   // free-form CSS font-family stack entry
    private var fontPickerButton: NSButton!     // opens NSFontPanel (replaces import button)
    private var themePopup: NSPopUpButton!
    private var bgColorWell: NSColorWell!
    private var textColorWell: NSColorWell!
    private var lineHeightSlider: NSSlider!
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
    private var bgColorGridRow: NSGridRow!
    private var textColorGridRow: NSGridRow!
    private var presetsGridRow: NSGridRow!
    private var savePresetGridRow: NSGridRow!

    /// The currently previewed font name when the NSFontPanel is used
    private var pickedFontName: String = SettingsManager.shared.customFontName

    /// Index of the synthetic "Custom…" item, appended after all presets.
    private var customFontPopupIndex: Int { FontPresets.all.count }

    override func loadView() {
        NSLog("[Honeycrisp][Settings] AppearanceSettingsViewController.loadView start")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))

        // ── Preview strip ────────────────────────────────────────────────────
        previewBox = NSBox()
        previewBox.boxType = .custom
        previewBox.cornerRadius = 8
        previewBox.borderWidth = 1
        previewBox.borderColor = .separatorColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.heightAnchor.constraint(equalToConstant: 64).isActive = true

        previewLabel = NSTextField(wrappingLabelWithString: "The quick brown fox jumps over the lazy dog.")
        previewLabel.alignment = .left
        previewLabel.isEditable = false
        previewLabel.isSelectable = false
        previewLabel.isBezeled = false
        previewLabel.drawsBackground = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewBox.contentView?.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: previewBox.contentView!.leadingAnchor, constant: 14),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.contentView!.trailingAnchor, constant: -14),
            previewLabel.centerYAnchor.constraint(equalTo: previewBox.contentView!.centerYAnchor),
        ])

        // ── Form grid ────────────────────────────────────────────────────────
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        addSectionHeader("Typography", to: grid)
        grid.addRow(with: [label("Font:"), makeFontPopup()])
        fontFamilyFieldRow = grid.addRow(with: [NSGridCell.emptyContentView, makeFontFamilyField()])
        fontPickerButtonRow = grid.addRow(with: [NSGridCell.emptyContentView, makeFontPickerButton()])
        grid.addRow(with: [label("Font Size:"), makeFontSizeRow()])
        grid.addRow(with: [label("Line Height:"), makeLineHeightSlider()])

        addSectionHeader("Colors", to: grid)
        grid.addRow(with: [label("Theme:"), makeThemePopup()])
        bgColorWell = makeColorWell(action: #selector(bgColorChanged(_:)))
        bgColorGridRow = grid.addRow(with: [label("Background:"), bgColorWell])
        textColorWell = makeColorWell(action: #selector(textColorChanged(_:)))
        textColorGridRow = grid.addRow(with: [label("Text Color:"), textColorWell])
        presetsRow = makePresetsRow()
        presetsGridRow = grid.addRow(with: [label("Presets:"), presetsRow])
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

        // ── Scroll view (Appearance's content is taller than the window;
        // this is the fix for the tab being unreachable below the fold) ──────
        let formStack = NSStackView(views: [previewBox, grid])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 16
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
            // vertical scrolling happens; height is left to the stack's
            // intrinsic content size, which is what makes scrolling work.
            clipContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        self.view = root

        updateCustomModeVisibility()
        updateColorRowsVisibility()
        refreshPreview()
        NSLog("[Honeycrisp][Settings] AppearanceSettingsViewController.loadView done")
    }

    // MARK: - Control Factories

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func addSectionHeader(_ title: String, to grid: NSGridView) {
        let header = NSTextField(labelWithString: title)
        header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let row = grid.addRow(with: [header, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.topPadding = grid.numberOfRows == 1 ? 0 : 10
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
        // Free-form CSS font-family entry — visible only when "Custom…" is
        // selected. fontFamily is a plain string, not a fixed enum, so any CSS
        // font stack the user types is accepted as-is.
        let field = NSTextField(string: SettingsManager.shared.fontFamily)
        field.target = self
        field.action = #selector(fontFamilyFieldChanged(_:))
        field.placeholderString = "e.g. Georgia, serif"
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        fontFamilyField = field
        return field
    }

    private func makeFontPickerButton() -> NSButton {
        // Alternative to typing a stack by hand; picking a font here overwrites
        // fontFamily with its PostScript name and switches the popup to
        // "Custom…". Only shown/hidden together with fontFamilyField (both are
        // Custom-mode-only controls) -- see updateCustomModeVisibility().
        let button = NSButton(
            title: pickedFontName.isEmpty ? "Choose Font…" : pickedFontName,
            target: self,
            action: #selector(openFontPanel(_:))
        )
        button.bezelStyle = .rounded
        fontPickerButton = button
        return button
    }

    /// Selects the preset item matching `family`'s CSS stack exactly, or the
    /// "Custom…" item if `family` doesn't match any known preset (a
    /// hand-typed stack, or one written by the NSFontPanel).
    private func selectFontPopupItem(forCurrentFontFamily family: String) {
        if let idx = FontPresets.all.firstIndex(where: { $0.cssStack == family }) {
            fontPopup.selectItem(at: idx)
        } else {
            fontPopup.selectItem(at: customFontPopupIndex)
        }
    }

    private func makeThemePopup() -> NSPopUpButton {
        themePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        themePopup.addItems(withTitles: ReaderTheme.allCases.map { $0.displayName })
        themePopup.selectItem(at: SettingsManager.shared.currentTheme.rawValue)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        return themePopup
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

    private func makeLineHeightSlider() -> NSView {
        let slider = NSSlider(value: SettingsManager.shared.lineHeight, minValue: 1.2, maxValue: 2.4, target: self, action: #selector(lineHeightChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.setAccessibilityLabel("Line Height")
        lineHeightSlider = slider
        return slider
    }

    /// Single parameterized factory replacing four near-identical
    /// stepper+label row builders (font size / max width / h margin / v
    /// margin). Returns the row view; the stepper and label are handed back
    /// via the completion closure so callers can retain references and wire
    /// up their own @objc action selector (steppers need a concrete target
    /// action, so the caller still owns that part).
    private func makeStepperRow(
        label accessibilityName: String,
        min: Double, max: Double, increment: Double,
        initialValue: Int, unit: String,
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
        s.setAccessibilityValueDescription("\(initialValue) \(unit)")
        stepper = s

        let l = NSTextField(labelWithString: "\(initialValue)\(unit == "percent" ? "%" : "px")")
        l.font = NSFont.systemFont(ofSize: 13)
        valueLabel = l

        row.addArrangedSubview(s)
        row.addArrangedSubview(l)
        return row
    }

    private func makeFontSizeRow() -> NSView {
        makeStepperRow(
            label: "Font Size", min: 50, max: 300, increment: 10,
            initialValue: SettingsManager.shared.fontSizePercent, unit: "percent",
            action: #selector(fontSizeStepperChanged(_:)),
            stepper: &fontSizeStepper, valueLabel: &fontSizeLabel
        )
    }

    private func makeMaxWidthRow() -> NSView {
        makeStepperRow(
            label: "Max Width", min: 320, max: 1400, increment: 20,
            initialValue: SettingsManager.shared.maxWidth, unit: "px",
            action: #selector(maxWidthStepperChanged(_:)),
            stepper: &maxWidthStepper, valueLabel: &maxWidthLabel
        )
    }

    private func makePaddingHRow() -> NSView {
        makeStepperRow(
            label: "Horizontal Margin", min: 0, max: 120, increment: 4,
            initialValue: SettingsManager.shared.paddingH, unit: "px",
            action: #selector(paddingHStepperChanged(_:)),
            stepper: &paddingHStepper, valueLabel: &paddingHLabel
        )
    }

    private func makePaddingVRow() -> NSView {
        makeStepperRow(
            label: "Vertical Margin", min: 0, max: 120, increment: 4,
            initialValue: SettingsManager.shared.paddingV, unit: "px",
            action: #selector(paddingVStepperChanged(_:)),
            stepper: &paddingVStepper, valueLabel: &paddingVLabel
        )
    }

    // MARK: - Visibility

    /// fontFamilyField and fontPickerButton are both Custom-mode-only controls
    /// (the preset popup and the font panel/free-text entry are alternative
    /// ways to set the same fontFamily value) -- shown/hidden together rather
    /// than the font-picker button always being visible regardless of mode.
    private func updateCustomModeVisibility() {
        let isCustomFont = !FontPresets.all.contains { $0.cssStack == SettingsManager.shared.fontFamily }
        fontFamilyFieldRow.isHidden = !isCustomFont
        fontPickerButtonRow.isHidden = !isCustomFont
    }

    private func updateColorRowsVisibility() {
        let isCustomTheme = SettingsManager.shared.currentTheme == .custom
        if let well = bgColorWell {
            well.color = SettingsManager.color(fromCSS: SettingsManager.shared.customBackgroundCSS)
        }
        if let well = textColorWell {
            well.color = SettingsManager.color(fromCSS: SettingsManager.shared.customTextCSS)
        }
        bgColorGridRow.isHidden = !isCustomTheme
        textColorGridRow.isHidden = !isCustomTheme
        presetsGridRow.isHidden = !isCustomTheme
        savePresetGridRow.isHidden = !isCustomTheme
    }

    /// Renders the current theme/font-size/line-height combination against a
    /// line of real sample text, so the effect of a change is visible without
    /// leaving Settings. Best-effort on the font: fontFamily is a CSS stack
    /// (e.g. "Georgia, serif"), not directly usable as an NSFont name, so this
    /// takes the first family name in the stack and falls back to the system
    /// font if AppKit doesn't have a font by that name -- exact CSS font
    /// resolution is WebKit's job when actually rendering the book.
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

        let baseSize = 13.0 * Double(SettingsManager.shared.fontSizePercent) / 100.0
        let firstFamily = SettingsManager.shared.fontFamily
            .split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? ""
        previewLabel.font = NSFont(name: firstFamily, size: CGFloat(baseSize))
            ?? NSFont.systemFont(ofSize: CGFloat(baseSize))
    }

    // MARK: - Actions

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx < FontPresets.all.count {
            SettingsManager.shared.fontFamily = FontPresets.all[idx].cssStack
        } else {
            // "Custom…" selected — keep whatever fontFamily already is (hand-
            // typed or NSFontPanel-picked) and reveal the free-form field.
            fontFamilyField.stringValue = SettingsManager.shared.fontFamily
        }
        updateCustomModeVisibility()
        refreshPreview()
    }

    @objc private func fontFamilyFieldChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        SettingsManager.shared.fontFamily = value
        refreshPreview()
    }

    /// Opens the native macOS font picker panel.
    /// When the user picks a font, `changeFont(_:)` is called by the responder chain.
    @objc private func openFontPanel(_ sender: Any?) {
        let panel = NSFontPanel.shared
        panel.worksWhenModal = true
        // Pre-select the currently saved custom font if one exists
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
        let psName = newFont.fontName   // PostScript name, usable in CSS
        pickedFontName = psName
        SettingsManager.shared.customFontName = psName
        SettingsManager.shared.fontFamily = "'\(psName)', sans-serif"
        fontPickerButton.title = newFont.displayName ?? psName
        fontFamilyField.stringValue = SettingsManager.shared.fontFamily
        selectFontPopupItem(forCurrentFontFamily: SettingsManager.shared.fontFamily)
        updateCustomModeVisibility()
        refreshPreview()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        if let theme = ReaderTheme(rawValue: sender.indexOfSelectedItem) {
            SettingsManager.shared.currentTheme = theme
            updateColorRowsVisibility()
            refreshPreview()
        }
    }

    @objc private func bgColorChanged(_ sender: NSColorWell) {
        SettingsManager.shared.customBackgroundCSS = SettingsManager.cssHex(from: sender.color)
        refreshPreview()
    }

    @objc private func textColorChanged(_ sender: NSColorWell) {
        SettingsManager.shared.customTextCSS = SettingsManager.cssHex(from: sender.color)
        refreshPreview()
    }

    @objc private func lineHeightChanged(_ sender: NSSlider) {
        SettingsManager.shared.lineHeight = sender.doubleValue
    }

    @objc private func fontSizeStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.fontSizePercent = sender.integerValue
        fontSizeLabel.stringValue = "\(SettingsManager.shared.fontSizePercent)%"
        sender.setAccessibilityValueDescription("\(SettingsManager.shared.fontSizePercent) percent")
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

    /// Resets every reader appearance/layout setting to its default and
    /// refreshes every control in this tab to match — mirrors Ambrosia's
    /// isReaderCustomized/resetReaderToDefaults pattern.
    @objc private func resetToDefaults(_ sender: NSButton) {
        SettingsManager.shared.resetReaderToDefaults()

        selectFontPopupItem(forCurrentFontFamily: SettingsManager.shared.fontFamily)
        fontFamilyField.stringValue = SettingsManager.shared.fontFamily
        themePopup?.selectItem(at: SettingsManager.shared.currentTheme.rawValue)
        lineHeightSlider.doubleValue = SettingsManager.shared.lineHeight
        fontSizeStepper.integerValue = SettingsManager.shared.fontSizePercent
        fontSizeLabel.stringValue = "\(SettingsManager.shared.fontSizePercent)%"
        maxWidthStepper.integerValue = SettingsManager.shared.maxWidth
        maxWidthLabel.stringValue = "\(SettingsManager.shared.maxWidth)px"
        paddingHStepper.integerValue = SettingsManager.shared.paddingH
        paddingHLabel.stringValue = "\(SettingsManager.shared.paddingH)px"
        paddingVStepper.integerValue = SettingsManager.shared.paddingV
        paddingVLabel.stringValue = "\(SettingsManager.shared.paddingV)px"
        linkClicksCheckbox.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
        updateCustomModeVisibility()
        updateColorRowsVisibility()
        refreshPreview()
    }

    /// Prompts for a name via an NSAlert with an accessory text field (Honeycrisp has
    /// no existing sheet/prompt pattern to match, so this is the simplest correct
    /// addition) and appends a SavedTheme built from the current custom colors.
    @objc private func saveAsPreset(_ sender: NSButton) {
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

    /// Sets currentTheme = .custom and overwrites the custom colors from the clicked
    /// preset. This is a cosmetic change -- no reload needed.
    @objc private func presetSwatchClicked(_ sender: ThemeSwatchButton) {
        SettingsManager.shared.currentTheme = .custom
        SettingsManager.shared.customBackgroundCSS = sender.preset.backgroundCSS
        SettingsManager.shared.customTextCSS = sender.preset.textCSS
        themePopup?.selectItem(at: ReaderTheme.custom.rawValue)
        updateColorRowsVisibility()
        refreshPreview()
    }

    private func deletePreset(_ preset: SavedTheme) {
        SettingsManager.shared.savedThemes.removeAll { $0.id == preset.id }
        rebuildPresetSwatches(in: presetsRow)
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
