// ThemePopoverViewController.swift
// Quick Apple-Books-style theme switcher shown from the toolbar gear button.
//
// This is a fast path onto the same SettingsManager.shared.currentTheme
// property that AppDelegate's "Reading > Theme" menu already writes to
// (see AppDelegate.selectTheme(_:)), so the two stay in sync automatically —
// there's no separate state to reconcile. The full Settings window's General
// tab still owns everything else (fonts, columns, custom colors, shortcuts);
// this popover intentionally exposes only theme selection, mirroring how
// Apple Books' toolbar theme control is scoped to appearance alone.

import AppKit

final class ThemePopoverViewController: NSViewController {

    private var rows: [ThemeRowView] = []

    override func loadView() {
        let themes = SettingsManager.shared.themes
        let rowHeight: CGFloat = 36
        let headerHeight: CGFloat = 34
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: headerHeight + CGFloat(themes.count) * rowHeight + 8))
        container.translatesAutoresizingMaskIntoConstraints = false

        let headerLabel = NSTextField(labelWithString: "Theme")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),

            sep.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        var previousAnchor = sep.bottomAnchor
        for theme in themes {
            let row = ThemeRowView(theme: theme) { [weak self] selected in
                self?.select(selected)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)

            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: previousAnchor),
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            previousAnchor = row.bottomAnchor
            rows.append(row)
        }

        container.bottomAnchor.constraint(equalTo: previousAnchor, constant: 8).isActive = true

        self.view = container
        refreshCheckmarks()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshCheckmarks()
    }

    private func select(_ theme: Theme) {
        SettingsManager.shared.currentThemeID = theme.id
        refreshCheckmarks()
    }

    private func refreshCheckmarks() {
        let current = SettingsManager.shared.currentThemeID
        for row in rows {
            row.setSelected(row.theme.id == current)
        }
    }
}

// MARK: - ThemeRowView

private final class ThemeRowView: NSView {

    let theme: Theme
    private let onSelect: (Theme) -> Void

    private let swatch = NSView()
    private let label = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let button = NSButton()

    init(theme: Theme, onSelect: @escaping (Theme) -> Void) {
        self.theme = theme
        self.onSelect = onSelect
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 8
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.backgroundColor = swatchColor(for: theme).cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(swatch)

        label.stringValue = theme.name
        label.font = NSFont.systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkmark.contentTintColor = .controlAccentColor
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkmark)

        button.title = ""
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = #selector(tapped)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 16),
            swatch.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),
            checkmark.heightAnchor.constraint(equalToConstant: 14),

            button.topAnchor.constraint(equalTo: topAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Every theme is now user-editable and carries its own background for both
    /// system appearances, so the swatch just reads whichever one is currently
    /// active -- no more per-fixed-case switch.
    private func swatchColor(for theme: Theme) -> NSColor {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let css = isDark ? theme.dark.background : theme.light.background
        return NSColor(hexString: css) ?? .windowBackgroundColor
    }

    func setSelected(_ selected: Bool) {
        checkmark.isHidden = !selected
    }

    @objc private func tapped() {
        onSelect(theme)
    }
}

// MARK: - NSColor(hex)

private extension NSColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
