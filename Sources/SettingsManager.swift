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

/// One appearance's colors for a single system-appearance mode (light or dark).
/// All three are free-form CSS color strings ("#rrggbb"), not just background/text,
/// since links need their own themeable color too.
struct ThemeColorSet: Codable, Equatable {
    var background: String
    var text: String
    var link: String
}

/// A fully user-editable appearance: a name plus one ThemeColorSet per system
/// appearance mode. Replaces the old fixed `ReaderTheme` enum (System/Light/Dark/
/// Sepia/Custom) and the old `SavedTheme` preset-on-top-of-.custom model — there's
/// now exactly one kind of theme, and every one of them (including the seeded
/// defaults) can be renamed, recolored, duplicated, and deleted. The light/dark
/// split means a single theme auto-repaints when macOS's system appearance
/// changes, rather than needing a separate "System Colors" special case.
struct Theme: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var light: ThemeColorSet
    var dark: ThemeColorSet

    init(id: UUID = UUID(), name: String, light: ThemeColorSet, dark: ThemeColorSet) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
    }
}

enum ReadingMode: Int, CaseIterable {
    case scroll    = 0
    case paginated = 1
}

/// Mirrors the old fixed ReaderTheme's raw values (system/light/dark/sepia/custom
/// = 0-4). Kept only so `migrateLegacyThemes` can tell whether a pre-upgrade user
/// had `.custom` selected; it has no other use and isn't exposed anywhere.
private enum ReaderThemeLegacy: Int {
    case system = 0, light, dark, sepia, custom
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

    /// Seeded the first time `themes` is read with no stored value: Original
    /// (system-appearance-following light/near-black), Quiet (dark surface,
    /// muted text), Paper (warm off-white, sepia-adjacent). Order here is the
    /// order shown in both the Appearance grid and the toolbar popover.
    private static let seedThemes: [Theme] = [
        Theme(name: "Original",
              light: ThemeColorSet(background: "#ffffff", text: "#000000", link: "#0068da"),
              dark:  ThemeColorSet(background: "#1c1c1e", text: "#e8e0d4", link: "#5aa9ff")),
        Theme(name: "Quiet",
              light: ThemeColorSet(background: "#2c2c2c", text: "#8a8a8a", link: "#7fb2e8"),
              dark:  ThemeColorSet(background: "#1c1c1e", text: "#8a8a8a", link: "#7fb2e8")),
        Theme(name: "Paper",
              light: ThemeColorSet(background: "#f4ecd8", text: "#433422", link: "#8a5a2b"),
              dark:  ThemeColorSet(background: "#2b2216", text: "#d8c9a8", link: "#c99a55")),
    ]

    /// JSON-array-in-UserDefaults, same pattern as HistoryManager.entries. Migrates
    /// the old fixed ReaderTheme selection + single custom color pair into an
    /// equivalent seeded theme the first time this is read post-upgrade, so
    /// existing users don't lose their current look.
    var themes: [Theme] {
        get {
            if let data = defaults.data(forKey: "readerThemes"),
               let decoded = try? JSONDecoder().decode([Theme].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            let migrated = Self.migrateLegacyThemes(defaults: defaults)
            // Persist directly via `defaults`, not `self.themes = migrated` --
            // that would call this same getter's setter while the getter is
            // still on the stack, which Swift's exclusivity checking traps on
            // ("Attempting to access 'themes' within its own getter").
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: "readerThemes")
            }
            return migrated
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "readerThemes")
            }
            notifyChange()
        }
    }

    /// Builds the seed list, folding in the old `.custom` colors (if the user had
    /// set any) as an extra "Custom" theme so that data isn't silently dropped.
    private static func migrateLegacyThemes(defaults: UserDefaults) -> [Theme] {
        var result = seedThemes
        if defaults.object(forKey: "readerTheme") != nil,
           ReaderThemeLegacy(rawValue: defaults.integer(forKey: "readerTheme")) == .custom {
            let bg = defaults.string(forKey: "readerCustomBg") ?? "#ffffff"
            let text = defaults.string(forKey: "readerCustomText") ?? "#000000"
            let custom = ThemeColorSet(background: bg, text: text, link: "#0068da")
            result.append(Theme(name: "Custom", light: custom, dark: custom))
        }
        return result
    }

    /// Which theme is active, by id. Falls back to the first theme (and repairs
    /// the stored id) if the previously-selected theme was deleted.
    var currentThemeID: UUID {
        get {
            let list = themes
            let stored = defaults.string(forKey: "readerCurrentThemeID").flatMap(UUID.init(uuidString:))
            if let stored, list.contains(where: { $0.id == stored }) { return stored }
            return list.first?.id ?? UUID()
        }
        set { defaults.set(newValue.uuidString, forKey: "readerCurrentThemeID"); notifyCosmeticChange() }
    }

    var currentTheme: Theme {
        let list = themes
        return list.first(where: { $0.id == currentThemeID }) ?? list[0]
    }

    /// True when NSApp's effective appearance is dark — used to pick which of a
    /// theme's two ThemeColorSets is currently in effect. Read fresh each time
    /// rather than cached, since the system can flip appearance at any moment.
    private var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The active theme's color set for the current system appearance.
    var effectiveColorSet: ThemeColorSet {
        systemIsDark ? currentTheme.dark : currentTheme.light
    }

    var effectiveBackgroundCSS: String { effectiveColorSet.background }
    var effectiveTextCSS: String { effectiveColorSet.text }
    var effectiveLinkCSS: String { effectiveColorSet.link }

    /// Persists an edited/renamed/recolored theme back into the list, matched by id.
    func updateTheme(_ theme: Theme) {
        var list = themes
        guard let idx = list.firstIndex(where: { $0.id == theme.id }) else { return }
        list[idx] = theme
        themes = list
    }

    /// Appends a new theme (e.g. from the "+" tile) and makes it the active one.
    func addTheme(_ theme: Theme) {
        themes.append(theme)
        currentThemeID = theme.id
    }

    /// Removes a theme. No-ops if it's the last remaining one. If the deleted
    /// theme was active, falls back to the first remaining theme.
    func deleteTheme(_ id: UUID) {
        var list = themes
        guard list.count > 1, let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: idx)
        themes = list
        if currentThemeID == id { currentThemeID = list[0].id }
    }

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

    // MARK: - Reset to defaults (Appearance tab)

    /// True only when at least one reader appearance/layout setting differs
    /// from its default — mirrors Ambrosia's `isReaderCustomized`, so the
    /// "Reset to Defaults" button is inert rather than an always-live
    /// destructive action. The theme list itself is deliberately excluded —
    /// there's no single "default" theme list to reset to, only which one
    /// is currently selected.
    var isReaderCustomized: Bool {
        fontFamily != FontPresets.defaultStack
            || currentThemeID != themes.first?.id
            || lineHeight != 1.6
            || fontSizePercent != 100
            || maxWidth != 700
            || paddingH != 24
            || paddingV != 24
            || allowReaderLinkClicks != false
    }

    func resetReaderToDefaults() {
        fontFamily = FontPresets.defaultStack
        currentThemeID = themes.first?.id ?? currentThemeID
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
