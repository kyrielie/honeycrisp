// SettingsManager.swift
//
// CHANGES vs original:
//  • showTitleInMenuBar property REMOVED — title is always shown in the toolbar
//  • formatFirstChapter key retained; semantics renamed to "Format for AO3"
//    (the key name is unchanged so existing UserDefaults values are preserved)

import AppKit

// MARK: - Models

/// A named font-family CSS stack offered in the Appearance settings font
/// popup as a quick-recall shortcut — distinct from the free-form
/// `SettingsManager.fontFamily` string the same way `SavedTheme` is distinct
/// from `customBackgroundCSS`/`customTextCSS`. Replaces the old fixed
/// `ReaderFont` enum (ported from Ambrosia's `ReaderPreferences.FontPreset`).
struct FontPreset: Identifiable {
    let id: String
    let label: String
    let cssStack: String
}

enum FontPresets {
    static let all: [FontPreset] = [
        FontPreset(id: "system",    label: "System (SF Pro)",  cssStack: "ui-sans-serif, -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"),
        FontPreset(id: "newyork",   label: "Serif (New York)", cssStack: "ui-serif, Georgia, serif"),
        FontPreset(id: "monospace", label: "Monospace",        cssStack: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"),
        FontPreset(id: "iowan",     label: "Iowan Old Style",  cssStack: "\"Iowan Old Style\", Georgia, serif"),
        FontPreset(id: "georgia",   label: "Georgia",          cssStack: "Georgia, serif"),
        FontPreset(id: "palatino",  label: "Palatino",         cssStack: "Palatino, 'Palatino Linotype', serif"),
        FontPreset(id: "times",     label: "Times New Roman",  cssStack: "'Times New Roman', Times, serif"),
        FontPreset(id: "charter",   label: "Charter",          cssStack: "Charter, Georgia, serif"),
        FontPreset(id: "avenir",    label: "Avenir Next",      cssStack: "'Avenir Next', Avenir, sans-serif"),
        FontPreset(id: "seravek",   label: "Seravek",          cssStack: "Seravek, 'Gill Sans', sans-serif"),
        FontPreset(id: "courier",   label: "Courier New",      cssStack: "'Courier New', Courier, monospace"),
    ]

    /// Falls back to the first preset (System/SF Pro) rather than a second
    /// hardcoded literal elsewhere, so there's one definition of "the default
    /// font stack".
    static var defaultStack: String { all[0].cssStack }
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

    /// Free-form CSS font-family stack (Ambrosia-style) — replaces the old
    /// fixed `ReaderFont` enum. Migrates a legacy `readerFont` raw value (the
    /// old enum's 0-3 range) into an equivalent CSS stack the first time this
    /// is read, so existing users don't silently lose their chosen font on
    /// upgrade.
    var fontFamily: String {
        get {
            if let stored = defaults.string(forKey: "readerFontFamily") { return stored }
            if defaults.object(forKey: "readerFont") != nil {
                return Self.migrateLegacyFontFamily(defaults: defaults)
            }
            return FontPresets.defaultStack
        }
        set { defaults.set(newValue, forKey: "readerFontFamily"); notifyCosmeticChange() }
    }

    /// PostScript name of the font most recently chosen via NSFontPanel — kept
    /// only so the panel can pre-select the same font next time it's opened;
    /// the CSS stack actually applied lives in `fontFamily`.
    var customFontName: String {
        get { defaults.string(forKey: "readerCustomFontName") ?? "" }
        set { defaults.set(newValue, forKey: "readerCustomFontName") }
    }

    private static func migrateLegacyFontFamily(defaults: UserDefaults) -> String {
        switch defaults.integer(forKey: "readerFont") {
        case 1: return FontPresets.all.first { $0.id == "newyork" }?.cssStack ?? FontPresets.defaultStack
        case 2: return FontPresets.all.first { $0.id == "monospace" }?.cssStack ?? FontPresets.defaultStack
        case 3:
            let name = defaults.string(forKey: "readerCustomFontName") ?? ""
            return name.isEmpty ? FontPresets.defaultStack : "'\(name)', sans-serif"
        default:
            return FontPresets.defaultStack
        }
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

    /// Whether the toolbar's page-count label ("3 of 12 · Ch 2 of 20") is shown.
    /// Pure display toggle, no re-render of reader content needed — uses the
    /// generic notification rather than the cosmetic/structural ones.
    var showPageCount: Bool {
        get { defaults.object(forKey: "readerShowPageCount") == nil ? true : defaults.bool(forKey: "readerShowPageCount") }
        set { defaults.set(newValue, forKey: "readerShowPageCount"); notifyChange() }
    }

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

    // MARK: Reading-column geometry (ported from Ambrosia's ReaderPreferences)
    //
    // Structural, not cosmetic: in paginated mode these feed EPUBParser.
    // paginatedColumnCSS, which bakes fixed-px column geometry into the loaded
    // HTML computed against the current viewport — a live CSS-variable patch
    // can't retarget that, so a change requires the same full spine reload a
    // resize does. Scroll mode's #content also reads maxWidth/paddingH live via
    // CSS variables (see EPUBParser.readerVarsCSS), so scroll-mode readers get
    // the debounced reload rather than an instant patch, but never see stale
    // geometry.

    /// Reading-column max width in points. Default (700) matches the constant
    /// EPUBParser.paginatedColumnCSS previously hardcoded.
    var maxWidth: Int {
        get {
            let stored = defaults.integer(forKey: "readerMaxWidth")
            return stored == 0 ? 700 : stored
        }
        set { defaults.set(max(320, min(1400, newValue)), forKey: "readerMaxWidth"); notifyStructuralChange() }
    }

    /// Horizontal reading margin in points. Default (24) matches the constant
    /// previously hardcoded in EPUBParser.paginatedColumnCSS. 0 is a valid
    /// margin, so presence (not value) of the stored default is what's checked.
    var paddingH: Int {
        get {
            defaults.object(forKey: "readerPaddingH") == nil ? 24 : defaults.integer(forKey: "readerPaddingH")
        }
        set { defaults.set(max(0, min(120, newValue)), forKey: "readerPaddingH"); notifyStructuralChange() }
    }

    /// Vertical reading margin in points (paginated mode only — scroll mode's
    /// vertical spacing comes from #content's own fixed top/bottom padding).
    /// Default (24) matches the constant previously hardcoded in
    /// EPUBParser.paginatedColumnCSS.
    var paddingV: Int {
        get {
            defaults.object(forKey: "readerPaddingV") == nil ? 24 : defaults.integer(forKey: "readerPaddingV")
        }
        set { defaults.set(max(0, min(120, newValue)), forKey: "readerPaddingV"); notifyStructuralChange() }
    }

    /// Whether in-book links are clickable. Off by default, matching Ambrosia —
    /// most in-EPUB links are internal cross-references (footnotes, TOC) that
    /// are more often accidental-click hazards than useful navigation in a
    /// reader that already has its own TOC sidebar. Purely a CSS
    /// pointer-events toggle, so this is cosmetic, not structural.
    var allowReaderLinkClicks: Bool {
        get { defaults.bool(forKey: "readerAllowLinkClicks") }
        set { defaults.set(newValue, forKey: "readerAllowLinkClicks"); notifyCosmeticChange() }
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

    // MARK: - Reset to defaults (Appearance tab)

    /// True only when at least one reader appearance/layout setting differs
    /// from its default — mirrors Ambrosia's `isReaderCustomized`, so the
    /// "Reset to Defaults" button is inert rather than an always-live
    /// destructive action. Saved theme presets are deliberately excluded,
    /// same as Ambrosia's `savedThemes` — there's no "default" preset list to
    /// reset to.
    var isReaderCustomized: Bool {
        fontFamily != FontPresets.defaultStack
            || currentTheme != .system
            || lineHeight != 1.6
            || fontSizePercent != 100
            || maxWidth != 700
            || paddingH != 24
            || paddingV != 24
            || allowReaderLinkClicks != false
    }

    func resetReaderToDefaults() {
        fontFamily = FontPresets.defaultStack
        currentTheme = .system
        lineHeight = 1.6
        fontSizePercent = 100
        maxWidth = 700
        paddingH = 24
        paddingV = 24
        allowReaderLinkClicks = false
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
