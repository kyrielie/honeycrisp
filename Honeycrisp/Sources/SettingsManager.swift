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
        case .system: return "transparent" // Lets NSVisualEffectView shine through
        case .light: return "#ffffff"
        case .dark: return "#1c1c1e"
        case .sepia: return "#f4ecd8"
        }
    }
    
    var cssText: String {
        switch self {
        case .system: return "var(--system-text)" // FIX: Replaced "inherit" with a mapped variable
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
    
    private func notifyChange() {
        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
    }
}

// MARK: - Settings Window & UI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        
        super.init(window: window)
        window.contentViewController = SettingsViewController()
    }
    
    required init?(coder: NSCoder) { fatalError() }
}

final class SettingsViewController: NSViewController {
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        
        let fontLabel = NSTextField(labelWithString: "Font:")
        fontLabel.isEditable = false
        fontLabel.isBordered = false
        fontLabel.backgroundColor = .clear
        
        let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopup.addItems(withTitles: ReaderFont.allCases.map { $0.displayName })
        fontPopup.selectItem(at: SettingsManager.shared.currentFont.rawValue)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        
        let themeLabel = NSTextField(labelWithString: "Theme:")
        themeLabel.isEditable = false
        themeLabel.isBordered = false
        themeLabel.backgroundColor = .clear
        
        let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        themePopup.addItems(withTitles: ReaderTheme.allCases.map { $0.displayName })
        themePopup.selectItem(at: SettingsManager.shared.currentTheme.rawValue)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        
        let stack = NSStackView(views: [
            createRow(label: fontLabel, control: fontPopup),
            createRow(label: themeLabel, control: themePopup)
        ])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        self.view = view
    }
    
    private func createRow(label: NSView, control: NSView) -> NSStackView {
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
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
