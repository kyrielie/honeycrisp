// SettingsWindowController.swift
//
// CHANGES vs original:
//  • TypographySettingsViewController tab removed entirely
//  • AppearanceSettingsViewController: custom font import replaced with
//    native macOS NSFontPanel; CustomFontStore kept as internal storage but
//    the "Import Font…" button is gone — users pick from installed system fonts
//  • ReaderFont.custom now always refers to the font chosen via NSFontPanel
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

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)
        ])

        self.view = root
    }

    @objc private func toggleFormatForAO3(_ sender: NSButton) {
        // SettingsManager still stores this as "formatFirstChapter" internally;
        // EPUBParser's behaviour is now global (not first-chapter-only) — see EPUBParser.
        SettingsManager.shared.formatFirstChapter = sender.state == .on
    }
}

// MARK: - Appearance Settings

final class AppearanceSettingsViewController: NSViewController {

    private var fontPopup: NSPopUpButton!
    private var fontPickerButton: NSButton!     // opens NSFontPanel (replaces import button)
    private var themePopup: NSPopUpButton!
    private var bgColorWell: NSColorWell!
    private var textColorWell: NSColorWell!

    /// The currently previewed font name when .custom is selected
    private var pickedFontName: String = SettingsManager.shared.customFontName

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Font row
        stack.addArrangedSubview(makeRow(label: "Font:", control: makeFontPopup()))

        // Font picker button — visible only when .custom is selected
        fontPickerButton = NSButton(
            title: pickedFontName.isEmpty ? "Choose Font…" : pickedFontName,
            target: self,
            action: #selector(openFontPanel(_:))
        )
        fontPickerButton.bezelStyle = .rounded
        fontPickerButton.isHidden = SettingsManager.shared.currentFont != .custom
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
        fontPopup.addItems(withTitles: ReaderFont.allCases.map { $0.displayName })
        fontPopup.selectItem(at: SettingsManager.shared.currentFont.rawValue)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        return fontPopup
    }

    private func makeThemePopup() -> NSPopUpButton {
        themePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        themePopup.addItems(withTitles: ReaderTheme.allCases.map { $0.displayName })
        themePopup.selectItem(at: SettingsManager.shared.currentTheme.rawValue)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        return themePopup
    }

    private func makeColorRow(label text: String, colorWell: inout NSColorWell!, selector: Selector) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        colorWell = NSColorWell()
        colorWell.target = self
        colorWell.action = selector
        return makeRow(label: label, control: colorWell)
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
                if sv.identifier?.rawValue == "bgColorRow" || sv.identifier?.rawValue == "textColorRow" {
                    sv.isHidden = !isCustomTheme
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard let font = ReaderFont(rawValue: sender.indexOfSelectedItem) else { return }
        SettingsManager.shared.currentFont = font
        fontPickerButton.isHidden = font != .custom
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
        fontPickerButton.title = newFont.displayName ?? psName
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
