// ThemePopoverViewController.swift
// Quick Apple-Books-style theme switcher shown from the toolbar theme button.
//
// This is a fast path onto the same SettingsManager.shared.currentTheme
// property that AppDelegate's "Reading > Theme" menu already writes to
// (see AppDelegate.selectTheme(_:)), so the two stay in sync automatically —
// there's no separate state to reconcile. The Settings window's Appearance
// tab still owns editing (colors, fonts, margins). This popover exposes theme
// selection plus the System/Light/Dark mode, both of which write through
// SettingsManager.

import AppKit

final class ThemePopoverViewController: NSViewController {

    private var rows: [ThemeRowView] = []
    private var modeControl: NSSegmentedControl?

    override func loadView() {
        let themes = SettingsManager.shared.themes
        let rowHeight: CGFloat = 36
        let headerHeight: CGFloat = 34
        let modeBlockHeight: CGFloat = 52
        let container = NSView(
            frame: NSRect(
                x: 0, y: 0, width: 220,
                height: headerHeight + CGFloat(themes.count) * rowHeight + 8 + modeBlockHeight))
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

        addModeBlock(to: container, below: previousAnchor)

        self.view = container
        refreshCheckmarks()
    }

    /// The separator and the appearance segmented control under the theme rows, pinned to the bottom of `container`.
    private func addModeBlock(to container: NSView, below previousAnchor: NSLayoutYAxisAnchor) {
        let modeSeparator = NSBox()
        modeSeparator.boxType = .separator
        modeSeparator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modeSeparator)

        let modes = AppearanceMode.allCases
        let modeControl = NSSegmentedControl(
            labels: modes.map(\.displayName), trackingMode: .selectOne,
            target: self, action: #selector(modeChanged(_:)))
        modeControl.controlSize = .small
        modeControl.selectedSegment = modes.firstIndex(of: SettingsManager.shared.appearanceMode) ?? 0
        modeControl.setAccessibilityLabel("Appearance")
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modeControl)
        self.modeControl = modeControl

        NSLayoutConstraint.activate([
            modeSeparator.topAnchor.constraint(equalTo: previousAnchor, constant: 6),
            modeSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            modeSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            modeControl.topAnchor.constraint(equalTo: modeSeparator.bottomAnchor, constant: 10),
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            modeControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            container.bottomAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshCheckmarks()
        if let index = AppearanceMode.allCases.firstIndex(of: SettingsManager.shared.appearanceMode) {
            modeControl?.selectedSegment = index
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let modes = AppearanceMode.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
        SettingsManager.shared.appearanceMode = modes[sender.selectedSegment]
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

    private let swatch = ThemeSwatchView()
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
        swatch.theme = theme
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

    func setSelected(_ selected: Bool) {
        checkmark.isHidden = !selected
    }

    @objc private func tapped() {
        onSelect(theme)
    }
}

// MARK: - ThemeSwatchView

/// 16pt rounded chip split diagonally into the theme's light and dark backgrounds. Drawn in
/// `draw(_:)`, so the border color re-resolves when the effective appearance changes.
private final class ThemeSwatchView: NSView {
    var theme: Theme? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (NSColor(hexString: theme.light.background) ?? .windowBackgroundColor).setFill()
        rect.fill()
        let darkHalf = NSBezierPath()
        darkHalf.move(to: NSPoint(x: rect.maxX, y: rect.maxY))
        darkHalf.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        darkHalf.line(to: NSPoint(x: rect.minX, y: rect.minY))
        darkHalf.close()
        (NSColor(hexString: theme.dark.background) ?? .windowBackgroundColor).setFill()
        darkHalf.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
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
