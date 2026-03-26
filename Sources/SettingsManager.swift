import AppKit

// MARK: - Models

enum ReaderFont: Int, CaseIterable {
    case sfPro = 0
    case serif
    case monospace
    
    var displayName: String {
        switch self {
        case .sfPro: return "System (SF Pro)"
        case .serif: return "Serif (New York)"
        case .monospace: return "Monospace"
        }
    }
    
    var cssValue: String {
        switch self {
        case .sfPro: return "ui-sans-serif, -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"
        case .serif: return "ui-serif, Georgia, serif"
        case .monospace: return "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"
        }
    }
}

enum ReaderTheme: Int, CaseIterable {
    case system = 0
    case light
    case dark
    case sepia
    
    var displayName: String {
        switch self {
        case .system: return "System Colors"
        case .light: return "Light"
        case .dark: return "Dark"
        case .sepia: return "Sepia"
        }
    }
    
    var cssBackground: String {
        switch self {
        case .system: return "transparent"
        case .light: return "#ffffff"
        case .dark: return "#1c1c1e"
        case .sepia: return "#f4ecd8"
        }
    }
    
    var cssText: String {
        switch self {
        case .system: return "var(--system-text)"
        case .light: return "#000000"
        case .dark: return "#e8e0d4"
        case .sepia: return "#433422"
        }
    }
}

// MARK: - Manager

final class SettingsManager {
    static let shared = SettingsManager()
    static let settingsChangedNotification = Notification.Name("ReaderSettingsChanged")
    
    private let defaults = UserDefaults.standard
    
    var currentFont: ReaderFont {
        get { ReaderFont(rawValue: defaults.integer(forKey: "readerFont")) ?? .sfPro }
        set {
            defaults.set(newValue.rawValue, forKey: "readerFont")
            notifyChange()
        }
    }
    
    var currentTheme: ReaderTheme {
        get { ReaderTheme(rawValue: defaults.integer(forKey: "readerTheme")) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "readerTheme")
            notifyChange()
        }
    }

    // FIX (Bug 2): Font size is now persisted in UserDefaults instead of living
    // as a transient instance variable on ReaderViewController.
    var fontSizePercent: Int {
        get {
            let stored = defaults.integer(forKey: "readerFontSize")
            return stored == 0 ? 100 : stored   // 0 means key was never written
        }
        set {
            let clamped = min(300, max(50, newValue))
            defaults.set(clamped, forKey: "readerFontSize")
            notifyChange()
        }
    }
    
    private func notifyChange() {
        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
    }
}

// MARK: - Settings Window & UI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Re-create the VC every time the window is shown. This avoids stale state
    // from a previously closed window whose view hierarchy was torn down.
    override func showWindow(_ sender: Any?) {
        window?.contentViewController = SettingsViewController()
        super.showWindow(sender)
    }
}

final class SettingsViewController: NSViewController {

    override func loadView() {
        // Must assign self.view before returning from loadView.
        // Use a concrete frame; the window will size to contentViewController automatically.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 130))
        self.view = root

        // Row 1 – Font
        let fontLabel = makeLabel("Font:")
        let fontPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        fontPopup.addItems(withTitles: ReaderFont.allCases.map { $0.displayName })
        fontPopup.selectItem(at: SettingsManager.shared.currentFont.rawValue)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))

        // Row 2 – Theme
        let themeLabel = makeLabel("Theme:")
        let themePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        themePopup.addItems(withTitles: ReaderTheme.allCases.map { $0.displayName })
        themePopup.selectItem(at: SettingsManager.shared.currentTheme.rawValue)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))

        let stack = NSStackView(views: [
            makeRow(label: fontLabel,  control: fontPopup),
            makeRow(label: themeLabel, control: themePopup)
        ])
        stack.orientation = .vertical
        stack.alignment = .right
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.isEditable = false
        tf.isBordered = false
        tf.backgroundColor = .clear
        return tf
    }

    private func makeRow(label: NSView, control: NSView) -> NSStackView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        if let font = ReaderFont(rawValue: sender.indexOfSelectedItem) {
            SettingsManager.shared.currentFont = font
        }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        if let theme = ReaderTheme(rawValue: sender.indexOfSelectedItem) {
            SettingsManager.shared.currentTheme = theme
        }
    }
}
