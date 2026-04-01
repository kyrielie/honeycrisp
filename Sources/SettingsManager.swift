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

// MARK: - Manager

final class SettingsManager {
    static let shared = SettingsManager()
    static let settingsChangedNotification = Notification.Name("ReaderSettingsChanged")

    private let defaults = UserDefaults.standard

    // MARK: Font

    var currentFont: ReaderFont {
        get { ReaderFont(rawValue: defaults.integer(forKey: "readerFont")) ?? .sfPro }
        set { defaults.set(newValue.rawValue, forKey: "readerFont"); notifyChange() }
    }

    /// PostScript name of the font chosen via NSFontPanel
    var customFontName: String {
        get { defaults.string(forKey: "readerCustomFontName") ?? "" }
        set { defaults.set(newValue, forKey: "readerCustomFontName"); notifyChange() }
    }

    // MARK: Theme

    var currentTheme: ReaderTheme {
        get { ReaderTheme(rawValue: defaults.integer(forKey: "readerTheme")) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "readerTheme"); notifyChange() }
    }

    var customBackgroundCSS: String {
        get { defaults.string(forKey: "readerCustomBg") ?? "#ffffff" }
        set { defaults.set(newValue, forKey: "readerCustomBg"); notifyChange() }
    }

    var customTextCSS: String {
        get { defaults.string(forKey: "readerCustomText") ?? "#000000" }
        set { defaults.set(newValue, forKey: "readerCustomText"); notifyChange() }
    }

    // MARK: Font size

    var fontSizePercent: Int {
        get {
            let stored = defaults.integer(forKey: "readerFontSize")
            return stored == 0 ? 100 : stored
        }
        set {
            defaults.set(min(300, max(50, newValue)), forKey: "readerFontSize")
            notifyChange()
        }
    }

    // MARK: Behaviour flags

    /// "Format for AO3" — removes toc-heading elements and enlarges calibre2 elements
    /// across ALL chapters (previously named "Format first chapter", now global).
    /// UserDefaults key unchanged to preserve existing user preference.
    var formatFirstChapter: Bool {
        get { defaults.bool(forKey: "readerFormatFirstChapter") }
        set { defaults.set(newValue, forKey: "readerFormatFirstChapter"); notifyChange() }
    }

    var removeFirstLine: Bool {
        get { defaults.bool(forKey: "readerRemoveFirstLine") }
        set { defaults.set(newValue, forKey: "readerRemoveFirstLine"); notifyChange() }
    }

    var enlargeSecondLine: Bool {
        get { defaults.bool(forKey: "readerEnlargeSecondLine") }
        set { defaults.set(newValue, forKey: "readerEnlargeSecondLine"); notifyChange() }
    }

    // MARK: -

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
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
