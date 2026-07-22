// SettingsManager.swift
//
// CHANGES vs original:
//  • showTitleInMenuBar property REMOVED — title is always shown in the toolbar
//  • formatFirstChapter key retained; semantics renamed to "Format for AO3"
//    (the key name is unchanged so existing UserDefaults values are preserved)

import AppKit

// MARK: - Models

enum ReaderFont: Int, CaseIterable {
    case sfPro = 0
    case serif
    case monospace
    case custom          // PostScript name stored in SettingsManager.customFontName

    var displayName: String {
        switch self {
        case .sfPro:      return "System (SF Pro)"
        case .serif:      return "Serif (New York)"
        case .monospace:  return "Monospace"
        case .custom:     return "Custom…"
        }
    }

    var cssValue: String {
        switch self {
        case .sfPro:     return "ui-sans-serif, -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"
        case .serif:     return "ui-serif, Georgia, serif"
        case .monospace: return "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"
        case .custom:
            let name = SettingsManager.shared.customFontName
            return name.isEmpty ? "ui-sans-serif, sans-serif" : "'\(name)', sans-serif"
        }
    }
}

enum ReaderTheme: Int, CaseIterable {
    case system = 0
    case light
    case dark
    case sepia
    case custom

    var displayName: String {
        switch self {
        case .system: return "System Colors"
        case .light:  return "Light"
        case .dark:   return "Dark"
        case .sepia:  return "Sepia"
        case .custom: return "Custom"
        }
    }

    var cssBackground: String {
        switch self {
        case .system: return "transparent"
        case .light:  return "#ffffff"
        case .dark:   return "#1c1c1e"
        case .sepia:  return "#f4ecd8"
        case .custom: return SettingsManager.shared.customBackgroundCSS
        }
    }

    var cssText: String {
        switch self {
        case .system: return "var(--system-text)"
        case .light:  return "#000000"
        case .dark:   return "#e8e0d4"
        case .sepia:  return "#433422"
        case .custom: return SettingsManager.shared.customTextCSS
        }
    }
}

enum ReadingMode: Int, CaseIterable {
    case scroll    = 0
    case paginated = 1
}

/// A named custom background/text color pair, saved on top of `.custom`. Distinct
/// from `ReaderTheme`'s fixed built-ins — presets are just quick-recall shortcuts for
/// `customBackgroundCSS`/`customTextCSS`.
struct SavedTheme: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var backgroundCSS: String   // "#RRGGBB"
    var textCSS: String

    init(name: String, backgroundCSS: String, textCSS: String) {
        self.id = UUID()
        self.name = name
        self.backgroundCSS = backgroundCSS
        self.textCSS = textCSS
    }
}

// MARK: - Manager

extension Notification.Name {
    /// Font/theme/colour/line-height changes: applied live via JS CSS-variable patch,
    /// no reload.
    static let readerCosmeticSettingsChanged = Notification.Name("readerCosmeticSettingsChanged")
    /// Changes that alter the HTML that gets built (formatting flags, pagination
    /// layout knobs): require re-rendering the current content.
    static let readerStructuralSettingsChanged = Notification.Name("readerStructuralSettingsChanged")
}

final class SettingsManager {
    static let shared = SettingsManager()
    static let settingsChangedNotification = Notification.Name("ReaderSettingsChanged")

    private let defaults = UserDefaults.standard

    // MARK: Font

    var currentFont: ReaderFont {
        get { ReaderFont(rawValue: defaults.integer(forKey: "readerFont")) ?? .sfPro }
        set { defaults.set(newValue.rawValue, forKey: "readerFont"); notifyCosmeticChange() }
    }

    /// PostScript name of the font chosen via NSFontPanel
    var customFontName: String {
        get { defaults.string(forKey: "readerCustomFontName") ?? "" }
        set { defaults.set(newValue, forKey: "readerCustomFontName"); notifyCosmeticChange() }
    }

    // MARK: Theme

    var currentTheme: ReaderTheme {
        get { ReaderTheme(rawValue: defaults.integer(forKey: "readerTheme")) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "readerTheme"); notifyCosmeticChange() }
    }

    var customBackgroundCSS: String {
        get { defaults.string(forKey: "readerCustomBg") ?? "#ffffff" }
        set { defaults.set(newValue, forKey: "readerCustomBg"); notifyCosmeticChange() }
    }

    var customTextCSS: String {
        get { defaults.string(forKey: "readerCustomText") ?? "#000000" }
        set { defaults.set(newValue, forKey: "readerCustomText"); notifyCosmeticChange() }
    }

    /// Effective background CSS for the active theme (system/light/dark/sepia read
    /// their fixed value, .custom reads customBackgroundCSS).
    var effectiveBackgroundCSS: String { currentTheme.cssBackground }

    /// Effective text CSS for the active theme.
    var effectiveTextCSS: String { currentTheme.cssText }

    // MARK: Line height

    /// Body line-height multiplier, applied as the `--reader-line-height` CSS
    /// variable. Default 1.6 matches the previously-hardcoded value exactly.
    var lineHeight: Double {
        get {
            let stored = defaults.double(forKey: "readerLineHeight")
            return stored == 0 ? 1.6 : stored
        }
        set {
            defaults.set(min(2.4, max(1.2, newValue)), forKey: "readerLineHeight")
            notifyCosmeticChange()
        }
    }

    // MARK: Font size

    var fontSizePercent: Int {
        get {
            let stored = defaults.integer(forKey: "readerFontSize")
            return stored == 0 ? 100 : stored
        }
        set {
            defaults.set(min(300, max(50, newValue)), forKey: "readerFontSize")
            notifyCosmeticChange()
        }
    }

    // MARK: Behaviour flags

    /// "Format for AO3" — removes toc-heading elements and enlarges calibre2 elements
    /// across ALL chapters (previously named "Format first chapter", now global).
    /// UserDefaults key unchanged to preserve existing user preference. Structural:
    /// changes the HTML that gets built.
    var formatFirstChapter: Bool {
        get { defaults.bool(forKey: "readerFormatFirstChapter") }
        set { defaults.set(newValue, forKey: "readerFormatFirstChapter"); notifyStructuralChange() }
    }

    var removeFirstLine: Bool {
        get { defaults.bool(forKey: "readerRemoveFirstLine") }
        set { defaults.set(newValue, forKey: "readerRemoveFirstLine"); notifyChange() }
    }

    var enlargeSecondLine: Bool {
        get { defaults.bool(forKey: "readerEnlargeSecondLine") }
        set { defaults.set(newValue, forKey: "readerEnlargeSecondLine"); notifyChange() }
    }

    /// Strips leading space/tab runs immediately inside paragraph-like elements, for
    /// books that fake first-line indentation with literal whitespace. Structural (it
    /// changes what HTML gets built), not cosmetic.
    var removeParagraphIndents: Bool {
        get { defaults.bool(forKey: "readerRemoveParagraphIndents") }
        set { defaults.set(newValue, forKey: "readerRemoveParagraphIndents"); notifyStructuralChange() }
    }

    // MARK: Pagination

    /// Global default for which mode a reader window opens in. Deliberately not
    /// per-book — every window opens in whatever the current global default is,
    /// not read from or written to HistoryEntry.
    var defaultReadingMode: ReadingMode {
        get { ReadingMode(rawValue: defaults.integer(forKey: "readerDefaultReadingMode")) ?? .scroll }
        set { defaults.set(newValue.rawValue, forKey: "readerDefaultReadingMode"); notifyStructuralChange() }
    }

    var colsPerScreen: ColsPerScreen {
        get { ColsPerScreen(rawValue: defaults.integer(forKey: "readerColsPerScreen")) ?? .one }
        set { defaults.set(newValue.rawValue, forKey: "readerColsPerScreen"); notifyStructuralChange() }
    }

    // MARK: Saved theme presets

    /// JSON-array-in-UserDefaults, same pattern as HistoryManager.entries.
    var savedThemes: [SavedTheme] {
        get {
            guard let data = defaults.data(forKey: "readerSavedThemes"),
                  let decoded = try? JSONDecoder().decode([SavedTheme].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "readerSavedThemes")
            }
            notifyChange()
        }
    }

    // MARK: -

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
    }

    /// Cosmetic changes also post the general notification, so anything (like
    /// HistorySettingsViewController) still watching the old generic notification
    /// keeps working unchanged.
    private func notifyCosmeticChange() {
        NotificationCenter.default.post(name: .readerCosmeticSettingsChanged, object: nil)
        notifyChange()
    }

    private func notifyStructuralChange() {
        NotificationCenter.default.post(name: .readerStructuralSettingsChanged, object: nil)
        notifyChange()
    }

    /// Convert an NSColor to a CSS hex string (#rrggbb)
    static func cssHex(from color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(c.redComponent   * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent  * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Convert a CSS hex string to NSColor
    static func color(fromCSS hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt32(h, radix: 16) else { return .black }
        return NSColor(
            red:   CGFloat((val >> 16) & 0xff) / 255,
            green: CGFloat((val >>  8) & 0xff) / 255,
            blue:  CGFloat( val        & 0xff) / 255,
            alpha: 1
        )
    }
}
