import AppKit

final class ThemePopoverViewController: NSViewController {
    private var rows: [SkinRowView] = []

    override func loadView() {
        SkinStore.shared.reload()
        let skins = SkinStore.shared.skins
        let rowHeight: CGFloat = 38
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 42 + CGFloat(skins.count) * rowHeight + 42))
        let title = NSTextField(labelWithString: "Reader Skin")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14)
        ])
        var previous = title.bottomAnchor
        for skin in skins {
            let row = SkinRowView(skin: skin) { [weak self] id in self?.select(id) }
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: previous, constant: 4),
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: rowHeight)
            ])
            previous = row.bottomAnchor
            rows.append(row)
        }
        let importButton = NSButton(title: "Import Skin…", target: self, action: #selector(importSkin))
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(importButton)
        NSLayoutConstraint.activate([
            importButton.topAnchor.constraint(equalTo: previous, constant: 7),
            importButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            importButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        view = container
        refreshCheckmarks()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshCheckmarks()
    }

    private func select(_ id: String) {
        SettingsManager.shared.readerSkinID = id
        refreshCheckmarks()
    }

    private func refreshCheckmarks() {
        let current = SettingsManager.shared.readerSkinID
        for row in rows { row.setSelected(row.skin.id == current) }
    }

    @objc private func importSkin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .directory]
        panel.message = "Choose an .nnwtheme folder or .nnwtheme.zip archive."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isZip = url.pathExtension.lowercased() == "zip" || values?.isDirectory != true
            let skin = isZip
                ? try SkinStore.shared.importSkin(zipURL: url)
                : try SkinStore.shared.importSkin(from: url)
            SettingsManager.shared.readerSkinID = skin.id
            loadView()
        } catch SkinImportError.duplicateIdentifier {
            let alert = NSAlert()
            alert.messageText = "Replace the installed skin?"
            alert.informativeText = "A skin with this identifier is already installed."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let isZip = url.pathExtension.lowercased() == "zip" || values?.isDirectory != true
                let skin = isZip
                    ? try SkinStore.shared.importSkin(zipURL: url, replacingExisting: true)
                    : try SkinStore.shared.importSkin(from: url, replacingExisting: true)
                SettingsManager.shared.readerSkinID = skin.id
                loadView()
            } catch { showImportError(error) }
        } catch { showImportError(error) }
    }

    private func showImportError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

private final class SkinRowView: NSView {
    let skin: ReaderSkin
    private let action: (String) -> Void
    private let swatch = NSView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()

    init(skin: ReaderSkin, action: @escaping (String) -> Void) {
        self.skin = skin
        self.action = action
        super.init(frame: .zero)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 7
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        let background = skin.light?.background ?? "#ffffff"
        swatch.layer?.backgroundColor = NSColor(hexString: background)?.cgColor ?? NSColor.windowBackgroundColor.cgColor
        label.stringValue = skin.name
        label.font = NSFont.systemFont(ofSize: 13)
        if skin.lowContrast { badge.stringValue = "Low contrast"; badge.textColor = .secondaryLabelColor; badge.font = .systemFont(ofSize: 10) }
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
        checkmark.contentTintColor = .controlAccentColor
        [swatch, label, badge, checkmark].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = #selector(tapped)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 18), swatch.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 10), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6), badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14), checkmark.heightAnchor.constraint(equalToConstant: 14),
            button.topAnchor.constraint(equalTo: topAnchor), button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    func setSelected(_ selected: Bool) { checkmark.isHidden = !selected }
    @objc private func tapped() { action(skin.id) }
}

private extension NSColor {
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let hex = UInt32(value, radix: 16) else { return nil }
        self.init(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
