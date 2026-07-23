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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        window.contentViewController = SettingsTabViewController()
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Tab View Controller

final class SettingsTabViewController: NSTabViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // Typography tab intentionally removed.
        let tabs: [(NSViewController, String, String)] = [
            (GeneralSettingsViewController(),    "General",    "gear"),
            (AppearanceSettingsViewController(), "Appearance", "paintbrush"),
            (HistorySettingsViewController(),    "History",    "clock"),
            (ShortcutsSettingsViewController(),  "Shortcuts",  "keyboard"),
        ]

        for (vc, label, symbol) in tabs {
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
    }
}

// MARK: - General Settings

final class GeneralSettingsViewController: NSViewController {

    override func loadView() {
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

    /// The currently previewed font name when the NSFontPanel is used
    private var pickedFontName: String = SettingsManager.shared.customFontName

    /// Index of the synthetic "Custom…" item, appended after all presets.
    private var customFontPopupIndex: Int { FontPresets.all.count }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Font row
        stack.addArrangedSubview(makeRow(label: "Font:", control: makeFontPopup()))

        // Free-form CSS font-family entry — visible only when "Custom…" is
        // selected. fontFamily is a plain string, not a fixed enum (Ambrosia-
        // style), so any CSS font stack the user types is accepted as-is.
        fontFamilyField = NSTextField(string: SettingsManager.shared.fontFamily)
        fontFamilyField.target = self
        fontFamilyField.action = #selector(fontFamilyFieldChanged(_:))
        fontFamilyField.placeholderString = "e.g. Georgia, serif"
        fontFamilyField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        fontFamilyField.isHidden = FontPresets.all.contains { $0.cssStack == SettingsManager.shared.fontFamily }
        stack.addArrangedSubview(fontFamilyField)

        // Font picker button — an alternative to typing a stack by hand;
        // picking a font here overwrites fontFamily with its PostScript name
        // and switches the popup to "Custom…".
        fontPickerButton = NSButton(
            title: pickedFontName.isEmpty ? "Choose Font…" : pickedFontName,
            target: self,
            action: #selector(openFontPanel(_:))
        )
        fontPickerButton.bezelStyle = .rounded
        stack.addArrangedSubview(fontPickerButton)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        stack.addArrangedSubview(sep)

        // Theme row
        stack.addArrangedSubview(makeRow(label: "Theme:", control: makeThemePopup()))

        // Custom colour rows
        let bgRow = makeColorRow(label: "Background:", colorWell: &bgColorWell, selector: #selector(bgColorChanged(_:)))
        bgRow.identifier = NSUserInterfaceItemIdentifier("bgColorRow")
        stack.addArrangedSubview(bgRow)

        let textRow = makeColorRow(label: "Text Color:", colorWell: &textColorWell, selector: #selector(textColorChanged(_:)))
        textRow.identifier = NSUserInterfaceItemIdentifier("textColorRow")
        stack.addArrangedSubview(textRow)

        // Saved presets — shown only when .custom is the active theme, same
        // visibility rule as the color wells above.
        presetsRow = makePresetsRow()
        presetsRow.identifier = NSUserInterfaceItemIdentifier("presetsRow")
        stack.addArrangedSubview(presetsRow)

        let savePresetButton = NSButton(title: "Save as Preset…", target: self, action: #selector(saveAsPreset(_:)))
        savePresetButton.bezelStyle = .rounded
        savePresetButton.identifier = NSUserInterfaceItemIdentifier("savePresetButton")
        stack.addArrangedSubview(savePresetButton)

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        stack.addArrangedSubview(sep2)

        // Font size — previously toolbar-only; Settings is the more discoverable
        // home for a range control per HIG, and costs nothing to expose here too.
        stack.addArrangedSubview(makeRow(label: "Font Size:", control: makeFontSizeStepper()))

        // Line height
        stack.addArrangedSubview(makeRow(label: "Line Height:", control: makeLineHeightSlider()))

        // Separator
        let sep3 = NSBox()
        sep3.boxType = .separator
        stack.addArrangedSubview(sep3)

        // Reading-column width / margins (ported from Ambrosia's maxWidth/
        // paddingH/paddingV — Honeycrisp previously hardcoded these)
        stack.addArrangedSubview(makeRow(label: "Max Width:", control: makeMaxWidthStepper()))
        stack.addArrangedSubview(makeRow(label: "Horizontal Margin:", control: makePaddingHStepper()))
        stack.addArrangedSubview(makeRow(label: "Vertical Margin:", control: makePaddingVStepper()))

        // Allow link clicks (ported from Ambrosia)
        linkClicksCheckbox = NSButton(
            checkboxWithTitle: "Allow link clicks",
            target: self,
            action: #selector(linkClicksChanged(_:))
        )
        linkClicksCheckbox.state = SettingsManager.shared.allowReaderLinkClicks ? .on : .off
        stack.addArrangedSubview(linkClicksCheckbox)

        // Reset to defaults (ported from Ambrosia's isReaderCustomized pattern)
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults(_:)))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])

        self.view = root

        updateColorWellsVisibility()
    }

    // MARK: - Control Factories

    private func makeFontPopup() -> NSPopUpButton {
        fontPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        fontPopup.addItems(withTitles: FontPresets.all.map { $0.label } + ["Custom…"])
        selectFontPopupItem(forCurrentFontFamily: SettingsManager.shared.fontFamily)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        return fontPopup
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

    private func makeColorRow(label text: String, colorWell: inout NSColorWell!, selector: Selector) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        colorWell = NSColorWell()
        colorWell.target = self
        colorWell.action = selector
        return makeRow(label: label, control: colorWell)
    }

    private func makeLineHeightSlider() -> NSView {
        let slider = NSSlider(value: SettingsManager.shared.lineHeight, minValue: 1.2, maxValue: 2.4, target: self, action: #selector(lineHeightChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        lineHeightSlider = slider
        return slider
    }

    private func makeFontSizeStepper() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let stepper = NSStepper()
        stepper.minValue = 50
        stepper.maxValue = 300
        stepper.increment = 10
        stepper.integerValue = SettingsManager.shared.fontSizePercent
        stepper.target = self
        stepper.action = #selector(fontSizeStepperChanged(_:))
        fontSizeStepper = stepper

        let label = NSTextField(labelWithString: "\(SettingsManager.shared.fontSizePercent)%")
        label.font = NSFont.systemFont(ofSize: 13)
        fontSizeLabel = label

        row.addArrangedSubview(stepper)
        row.addArrangedSubview(label)
        return row
    }

    private func makeMaxWidthStepper() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let stepper = NSStepper()
        stepper.minValue = 320
        stepper.maxValue = 1400
        stepper.increment = 20
        stepper.integerValue = SettingsManager.shared.maxWidth
        stepper.target = self
        stepper.action = #selector(maxWidthStepperChanged(_:))
        maxWidthStepper = stepper

        let label = NSTextField(labelWithString: "\(SettingsManager.shared.maxWidth)px")
        label.font = NSFont.systemFont(ofSize: 13)
        maxWidthLabel = label

        row.addArrangedSubview(stepper)
        row.addArrangedSubview(label)
        return row
    }

    private func makePaddingHStepper() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let stepper = NSStepper()
        stepper.minValue = 0
        stepper.maxValue = 120
        stepper.increment = 4
        stepper.integerValue = SettingsManager.shared.paddingH
        stepper.target = self
        stepper.action = #selector(paddingHStepperChanged(_:))
        paddingHStepper = stepper

        let label = NSTextField(labelWithString: "\(SettingsManager.shared.paddingH)px")
        label.font = NSFont.systemFont(ofSize: 13)
        paddingHLabel = label

        row.addArrangedSubview(stepper)
        row.addArrangedSubview(label)
        return row
    }

    private func makePaddingVStepper() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let stepper = NSStepper()
        stepper.minValue = 0
        stepper.maxValue = 120
        stepper.increment = 4
        stepper.integerValue = SettingsManager.shared.paddingV
        stepper.target = self
        stepper.action = #selector(paddingVStepperChanged(_:))
        paddingVStepper = stepper

        let label = NSTextField(labelWithString: "\(SettingsManager.shared.paddingV)px")
        label.font = NSFont.systemFont(ofSize: 13)
        paddingVLabel = label

        row.addArrangedSubview(stepper)
        row.addArrangedSubview(label)
        return row
    }

    private func makeRow(label text: String, control: NSView) -> NSStackView {
        makeRow(label: NSTextField(labelWithString: text), control: control)
    }

    private func makeRow(label: NSView, control: NSView) -> NSStackView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    // MARK: - Visibility

    private func updateColorWellsVisibility() {
        let isCustomTheme = SettingsManager.shared.currentTheme == .custom
        if let well = bgColorWell {
            well.color = SettingsManager.color(fromCSS: SettingsManager.shared.customBackgroundCSS)
        }
        if let well = textColorWell {
            well.color = SettingsManager.color(fromCSS: SettingsManager.shared.customTextCSS)
        }
        if let stack = view.subviews.first(where: { $0 is NSStackView }) as? NSStackView {
            for sv in stack.arrangedSubviews {
                if sv.identifier?.rawValue == "bgColorRow" || sv.identifier?.rawValue == "textColorRow"
                    || sv.identifier?.rawValue == "presetsRow" || sv.identifier?.rawValue == "savePresetButton" {
                    sv.isHidden = !isCustomTheme
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx < FontPresets.all.count {
            SettingsManager.shared.fontFamily = FontPresets.all[idx].cssStack
            fontFamilyField.isHidden = true
        } else {
            // "Custom…" selected — keep whatever fontFamily already is (hand-
            // typed or NSFontPanel-picked) and reveal the free-form field.
            fontFamilyField.stringValue = SettingsManager.shared.fontFamily
            fontFamilyField.isHidden = false
        }
    }

    @objc private func fontFamilyFieldChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        SettingsManager.shared.fontFamily = value
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
        fontFamilyField.isHidden = false
        selectFontPopupItem(forCurrentFontFamily: SettingsManager.shared.fontFamily)
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        if let theme = ReaderTheme(rawValue: sender.indexOfSelectedItem) {
            SettingsManager.shared.currentTheme = theme
            updateColorWellsVisibility()
        }
    }

    @objc private func bgColorChanged(_ sender: NSColorWell) {
        SettingsManager.shared.customBackgroundCSS = SettingsManager.cssHex(from: sender.color)
    }

    @objc private func textColorChanged(_ sender: NSColorWell) {
        SettingsManager.shared.customTextCSS = SettingsManager.cssHex(from: sender.color)
    }

    @objc private func lineHeightChanged(_ sender: NSSlider) {
        SettingsManager.shared.lineHeight = sender.doubleValue
    }

    @objc private func fontSizeStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.fontSizePercent = sender.integerValue
        fontSizeLabel.stringValue = "\(SettingsManager.shared.fontSizePercent)%"
    }

    @objc private func maxWidthStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.maxWidth = sender.integerValue
        maxWidthLabel.stringValue = "\(SettingsManager.shared.maxWidth)px"
    }

    @objc private func paddingHStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.paddingH = sender.integerValue
        paddingHLabel.stringValue = "\(SettingsManager.shared.paddingH)px"
    }

    @objc private func paddingVStepperChanged(_ sender: NSStepper) {
        SettingsManager.shared.paddingV = sender.integerValue
        paddingVLabel.stringValue = "\(SettingsManager.shared.paddingV)px"
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
        fontFamilyField.isHidden = FontPresets.all.contains { $0.cssStack == SettingsManager.shared.fontFamily }
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
        updateColorWellsVisibility()
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
    /// preset. This is a cosmetic change (Patch 0003's split) — no reload needed.
    @objc private func presetSwatchClicked(_ sender: ThemeSwatchButton) {
        SettingsManager.shared.currentTheme = .custom
        SettingsManager.shared.customBackgroundCSS = sender.preset.backgroundCSS
        SettingsManager.shared.customTextCSS = sender.preset.textCSS
        themePopup?.selectItem(at: ReaderTheme.custom.rawValue)
        updateColorWellsVisibility()
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
