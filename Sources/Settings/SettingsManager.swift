// SettingsManager.swift
//
// CHANGES vs original:
//  • showTitleInMenuBar property REMOVED — title is always shown in the toolbar
//  • formatFirstChapter key retained; semantics renamed to "Format for AO3"
//    (the key name is unchanged so existing UserDefaults values are preserved)

// swiftlint:disable file_length
import AppKit
import AVFoundation

/// Overrides the window chrome / system-level light-or-dark appearance,
/// independent of each theme's own light/dark ThemeColorSet (which still
/// follows whichever of these is effectively in use). "System" is the
/// default and existing behavior -- just track the OS.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

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
        FontPreset(
            id: "system", label: "System (SF Pro)",
            cssStack: "ui-sans-serif, -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"),
        FontPreset(id: "newyork", label: "Serif (New York)", cssStack: "ui-serif, Georgia, serif"),
        FontPreset(
            id: "monospace", label: "Monospace", cssStack: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"),
        FontPreset(id: "iowan", label: "Iowan Old Style", cssStack: "\"Iowan Old Style\", Georgia, serif"),
        FontPreset(id: "georgia", label: "Georgia", cssStack: "Georgia, serif"),
        FontPreset(id: "palatino", label: "Palatino", cssStack: "Palatino, 'Palatino Linotype', serif"),
        FontPreset(id: "times", label: "Times New Roman", cssStack: "'Times New Roman', Times, serif"),
        FontPreset(id: "charter", label: "Charter", cssStack: "Charter, Georgia, serif"),
        FontPreset(id: "avenir", label: "Avenir Next", cssStack: "'Avenir Next', Avenir, sans-serif"),
        FontPreset(id: "seravek", label: "Seravek", cssStack: "Seravek, 'Gill Sans', sans-serif"),
        FontPreset(id: "courier", label: "Courier New", cssStack: "'Courier New', Courier, monospace"),
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

enum ThemeTextAlignment: String, Codable, CaseIterable {
    case book
    case left
    case center
    case right
    case justify

    var label: String {
        switch self {
        case .book: return "Book Default"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .justify: return "Justified"
        }
    }

    var cssValue: String { self == .book ? "inherit" : rawValue }
}

enum ThemeBoldWeight: String, Codable, CaseIterable {
    case book, normal, medium, bold

    var cssValue: String {
        switch self {
        case .book: return "bolder"
        case .normal: return "400"
        case .medium: return "600"
        case .bold: return "700"
        }
    }
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
    // Per-theme typography/layout -- each theme remembers its own font, size,
    // line height, and margins now, not one setting shared across every theme.
    // Added after Theme first shipped, so decoding falls back per-field for
    // themes saved before these existed (SettingsManager.themes' getter also
    // does a one-time migration pass that backfills these from the old
    // *global* UserDefaults values instead of these hardcoded constants, so
    // upgrading doesn't silently reset anyone's chosen look -- these
    // per-field fallbacks here are just a safety net under that).
    var fontFamily: String
    var fontSizePercent: Int
    var lineHeight: Double
    var maxWidth: Int
    var paddingH: Int
    var paddingV: Int
    var textAlignment: ThemeTextAlignment
    var hyphenate: Bool
    var paragraphSpacing: Double
    var paragraphIndent: Double?
    var boldWeight: ThemeBoldWeight
    // True only for the three seeded themes (Original/Quiet/Paper). Drives
    // two things: deleteTheme(_:) refuses to remove these regardless of how
    // many themes exist, and resetReaderToDefaults() knows to restore these
    // from `seedThemes` rather than the shared "new custom theme" baseline.
    // Defaults to false so existing persisted (pre-flag) themes -- which are
    // all user-created by definition, since the seed themes are re-tagged
    // by id below -- decode as non-default.
    var isDefault: Bool
    // Stable identity of a seeded theme ("original", "quiet", "paper"); nil for
    // user-created themes. Reset and the customized check match seeds by this key,
    // not by name, so renaming a default theme cannot detach it from its seed.
    var seedKey: String?

    init(
        id: UUID = UUID(), name: String, light: ThemeColorSet, dark: ThemeColorSet,
        fontFamily: String = FontPresets.defaultStack,
        fontSizePercent: Int = 100,
        lineHeight: Double = 1.6,
        maxWidth: Int = 700,
        paddingH: Int = 24,
        paddingV: Int = 24,
        textAlignment: ThemeTextAlignment = .book,
        hyphenate: Bool = false,
        paragraphSpacing: Double = 1.0,
        paragraphIndent: Double? = nil,
        boldWeight: ThemeBoldWeight = .book,
        isDefault: Bool = false,
        seedKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        self.fontFamily = fontFamily
        self.fontSizePercent = fontSizePercent
        self.lineHeight = lineHeight
        self.maxWidth = maxWidth
        self.paddingH = paddingH
        self.paddingV = paddingV
        self.textAlignment = textAlignment
        self.hyphenate = hyphenate
        self.paragraphSpacing = paragraphSpacing
        self.paragraphIndent = paragraphIndent
        self.boldWeight = boldWeight
        self.isDefault = isDefault
        self.seedKey = seedKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, light, dark, fontFamily, fontSizePercent, lineHeight, maxWidth, paddingH, paddingV,
            textAlignment, hyphenate, paragraphSpacing, paragraphIndent, boldWeight, isDefault, seedKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        light = try values.decode(ThemeColorSet.self, forKey: .light)
        dark = try values.decode(ThemeColorSet.self, forKey: .dark)
        fontFamily = try values.decodeIfPresent(String.self, forKey: .fontFamily) ?? FontPresets.defaultStack
        fontSizePercent = try values.decodeIfPresent(Int.self, forKey: .fontSizePercent) ?? 100
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.6
        maxWidth = try values.decodeIfPresent(Int.self, forKey: .maxWidth) ?? 700
        paddingH = try values.decodeIfPresent(Int.self, forKey: .paddingH) ?? 24
        paddingV = try values.decodeIfPresent(Int.self, forKey: .paddingV) ?? 24
        textAlignment = try values.decodeIfPresent(ThemeTextAlignment.self, forKey: .textAlignment) ?? .book
        hyphenate = try values.decodeIfPresent(Bool.self, forKey: .hyphenate) ?? false
        paragraphSpacing = try values.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 1.0
        paragraphIndent = try values.decodeIfPresent(Double.self, forKey: .paragraphIndent)
        boldWeight = try values.decodeIfPresent(ThemeBoldWeight.self, forKey: .boldWeight) ?? .book
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        seedKey = try values.decodeIfPresent(String.self, forKey: .seedKey)
    }
}

struct ThemeExport: Codable {
    let version: Int
    let theme: Theme

    static func encode(_ theme: Theme) throws -> Data {
        try JSONEncoder().encode(ThemeExport(version: 1, theme: theme))
    }

    static func decode(_ data: Data) throws -> Theme {
        let document = try JSONDecoder().decode(ThemeExport.self, from: data)
        guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        var theme = document.theme
        theme = Theme(
            name: String(theme.name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Imported Theme" : String(theme.name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines),
            light: ThemeColorSet(
                background: ReaderCSSSanitizer.hexColor(theme.light.background, fallback: ReaderCSSSanitizer.fallbackBackground),
                text: ReaderCSSSanitizer.hexColor(theme.light.text, fallback: ReaderCSSSanitizer.fallbackText),
                link: ReaderCSSSanitizer.hexColor(theme.light.link, fallback: ReaderCSSSanitizer.fallbackLink)),
            dark: ThemeColorSet(
                background: ReaderCSSSanitizer.hexColor(theme.dark.background, fallback: "#1e1e1e"),
                text: ReaderCSSSanitizer.hexColor(theme.dark.text, fallback: "#eeeeee"),
                link: ReaderCSSSanitizer.hexColor(theme.dark.link, fallback: "#6ba8ff")),
            fontFamily: ReaderCSSSanitizer.fontFamily(theme.fontFamily),
            fontSizePercent: ReaderCSSSanitizer.fontSizePercent(theme.fontSizePercent),
            lineHeight: ReaderCSSSanitizer.lineHeight(theme.lineHeight),
            maxWidth: ReaderCSSSanitizer.maxWidth(theme.maxWidth),
            paddingH: ReaderCSSSanitizer.paddingH(theme.paddingH),
            paddingV: min(120, max(0, theme.paddingV)),
            textAlignment: theme.textAlignment,
            hyphenate: theme.hyphenate,
            paragraphSpacing: ReaderCSSSanitizer.paragraphSpacing(theme.paragraphSpacing),
            paragraphIndent: theme.paragraphIndent.map(ReaderCSSSanitizer.paragraphIndent),
            boldWeight: theme.boldWeight
        )
        return theme
    }
}

enum ReadingMode: Int, CaseIterable {
    case scroll = 0
    case paginated = 1
}

/// Where a newly-opened book's window lands relative to any existing reader
/// window. Persisted like `defaultReadingMode`. AppKit's own automatic window
/// tabbing is turned off at launch (see AppDelegate.applicationWillFinishLaunching)
/// so this explicit setting is the only thing controlling tab-vs-window behavior.
enum NewBookOpensIn: Int, CaseIterable {
    case newWindow = 0
    case newTab = 1

    var label: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        }
    }
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

// swiftlint:disable:next type_body_length
final class SettingsManager {
    static let shared = SettingsManager()
    static let settingsChangedNotification = Notification.Name("ReaderSettingsChanged")

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests can use an isolated suite instead of the app's domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Font

    /// Per-theme now -- see Theme.fontFamily's doc comment. Kept as the same
    /// accessor every other call site (EPUBParser, ReaderViewController, the
    /// Appearance tab) already uses; only the storage underneath moved.
    var fontFamily: String {
        get { currentTheme.fontFamily }
        set { mutateCurrentTheme { $0.fontFamily = newValue }; notifyCosmeticChange() }
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
    /// Internal (not private) so tests can check every seeded palette.
    static let seedThemes: [Theme] = [
        Theme(
            name: "Original",
            light: ThemeColorSet(background: "#ffffff", text: "#000000", link: "#0068da"),
            dark: ThemeColorSet(background: "#1c1c1e", text: "#e8e0d4", link: "#5aa9ff"),
            fontFamily: FontPresets.all.first { $0.id == "system" }!.cssStack,
            isDefault: true, seedKey: "original"),
        Theme(
            name: "Quiet",
            light: ThemeColorSet(background: "#2c2c2c", text: "#8a8a8a", link: "#7fb2e8"),
            dark: ThemeColorSet(background: "#1c1c1e", text: "#8a8a8a", link: "#7fb2e8"),
            fontFamily: FontPresets.all.first { $0.id == "iowan" }!.cssStack,
            isDefault: true, seedKey: "quiet"),
        Theme(
            name: "Paper",
            light: ThemeColorSet(background: "#f4ecd8", text: "#433422", link: "#8a5a2b"),
            dark: ThemeColorSet(background: "#2b2216", text: "#d8c9a8", link: "#c99a55"),
            fontFamily: FontPresets.all.first { $0.id == "georgia" }!.cssStack,
            isDefault: true, seedKey: "paper"),
    ]

    /// One-time migration for installs that persisted themes before `isDefault`
    /// existed: re-tags any stored theme whose name still matches a seed
    /// theme's name as default, so upgrading doesn't suddenly make Original/
    /// Quiet/Paper deletable or exempt them from Reset to Defaults. Best-effort
    /// only -- a user who had already renamed one of these before upgrading
    /// won't get it re-tagged, same tradeoff as any name-based migration.
    private static func backfillIsDefault(_ themes: [Theme]) -> [Theme] {
        let seedNames = Set(seedThemes.map(\.name))
        return themes.map { theme in
            var updatedTheme = theme
            if seedNames.contains(theme.name) { updatedTheme.isDefault = true }
            return updatedTheme
        }
    }

    /// One-time migration for themes persisted before `seedKey` existed. A default theme
    /// still carrying its seed name gets that seed's key. A default theme that was renamed
    /// before this migration cannot be matched to a seed any more, so it is demoted to an
    /// ordinary (deletable) theme rather than left as a default with no seed to reset to.
    /// Idempotent: after it runs, no theme is `isDefault` with a nil `seedKey`.
    static func backfillSeedKeys(_ themes: [Theme]) -> [Theme] {
        themes.map { theme in
            guard theme.isDefault, theme.seedKey == nil else { return theme }
            var updatedTheme = theme
            if let seed = seedThemes.first(where: { $0.name == theme.name }) {
                updatedTheme.seedKey = seed.seedKey
            } else {
                updatedTheme.isDefault = false
            }
            return updatedTheme
        }
    }

    /// JSON-array-in-UserDefaults, same pattern as HistoryManager.entries. Migrates
    /// the old fixed ReaderTheme selection + single custom color pair into an
    /// equivalent seeded theme the first time this is read post-upgrade, so
    /// existing users don't lose their current look.
    var themes: [Theme] {
        get {
            if let data = defaults.data(forKey: "readerThemes"),
                let decoded = try? JSONDecoder().decode([Theme].self, from: data),
                !decoded.isEmpty
            {
                if !Self.dataHasPerThemeTypography(data) {
                    // Pre-upgrade storage: every theme shared one global font/
                    // size/line-height/margin setting. Backfill each theme
                    // with whatever that global value currently is (not the
                    // Theme initializer's hardcoded constants) so upgrading
                    // doesn't silently reset anyone's chosen look, then
                    // persist the backfilled version so this only runs once.
                    let migrated = decoded.map { theme -> Theme in
                        var updatedTheme = theme
                        updatedTheme.fontFamily =
                            self.defaults.string(forKey: "readerFontFamily")
                            ?? (self.defaults.object(forKey: "readerFont") != nil
                                ? Self.migrateLegacyFontFamily(defaults: self.defaults)
                                : FontPresets.defaultStack)
                        let storedSize = self.defaults.integer(forKey: "readerFontSize")
                        updatedTheme.fontSizePercent = storedSize == 0 ? 100 : storedSize
                        let storedLineHeight = self.defaults.double(forKey: "readerLineHeight")
                        updatedTheme.lineHeight = storedLineHeight == 0 ? 1.6 : storedLineHeight
                        let storedMaxWidth = self.defaults.integer(forKey: "readerMaxWidth")
                        updatedTheme.maxWidth = storedMaxWidth == 0 ? 700 : storedMaxWidth
                        updatedTheme.paddingH =
                            self.defaults.object(forKey: "readerPaddingH") == nil
                            ? 24 : self.defaults.integer(forKey: "readerPaddingH")
                        updatedTheme.paddingV =
                            self.defaults.object(forKey: "readerPaddingV") == nil
                            ? 24 : self.defaults.integer(forKey: "readerPaddingV")
                        return updatedTheme
                    }
                    if let data = try? JSONEncoder().encode(migrated) {
                        defaults.set(data, forKey: "readerThemes")
                    }
                    return migrated
                }
                if !Self.dataHasIsDefaultFlag(data) {
                    let migrated = Self.backfillSeedKeys(Self.backfillIsDefault(decoded))
                    if let data = try? JSONEncoder().encode(migrated) {
                        defaults.set(data, forKey: "readerThemes")
                    }
                    return migrated
                }
                if decoded.contains(where: { $0.isDefault && $0.seedKey == nil }) {
                    let migrated = Self.backfillSeedKeys(decoded)
                    if let data = try? JSONEncoder().encode(migrated) {
                        defaults.set(data, forKey: "readerThemes")
                    }
                    return migrated
                }
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

    /// Whether stored theme JSON already includes the per-theme typography
    /// fields (added after Theme first shipped) -- checked on the raw JSON
    /// rather than via decoding, since Theme's own Codable fallbacks would
    /// otherwise mask "this hasn't been migrated yet" behind valid-looking
    /// hardcoded defaults.
    private static func dataHasPerThemeTypography(_ data: Data) -> Bool {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let first = array.first
        else { return true }
        return first["fontFamily"] != nil
    }

    /// Same pattern as `dataHasPerThemeTypography`, for the `isDefault` field
    /// added afterward -- checked on raw JSON so Theme's own Codable fallback
    /// (`?? false`) can't mask "this hasn't been migrated yet".
    private static func dataHasIsDefaultFlag(_ data: Data) -> Bool {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let first = array.first
        else { return true }
        return first["isDefault"] != nil
    }

    /// Builds the seed list, folding in the old `.custom` colors (if the user had
    /// set any) as an extra "Custom" theme so that data isn't silently dropped.
    private static func migrateLegacyThemes(defaults: UserDefaults) -> [Theme] {
        var result = seedThemes
        if defaults.object(forKey: "readerTheme") != nil,
            ReaderThemeLegacy(rawValue: defaults.integer(forKey: "readerTheme")) == .custom
        {
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

    /// Removes a theme. No-ops if it's the last remaining one, or if it's one
    /// of the three default themes (Original/Quiet/Paper) -- those can be
    /// edited and reset, but never deleted. If the deleted theme was active,
    /// falls back to the first remaining theme.
    func deleteTheme(_ id: UUID) {
        var list = themes
        guard list.count > 1,
            let idx = list.firstIndex(where: { $0.id == id }),
            !list[idx].isDefault
        else { return }
        list.remove(at: idx)
        themes = list
        if currentThemeID == id { currentThemeID = list[0].id }
    }

    // MARK: Line height

    /// Per-theme now -- see Theme.lineHeight's doc comment.
    var lineHeight: Double {
        get { currentTheme.lineHeight }
        set { mutateCurrentTheme { $0.lineHeight = ReaderCSSSanitizer.lineHeight(newValue) }; notifyCosmeticChange() }
    }

    // MARK: Font size

    /// Per-theme now -- see Theme.fontSizePercent's doc comment.
    var fontSizePercent: Int {
        get { currentTheme.fontSizePercent }
        set { mutateCurrentTheme { $0.fontSizePercent = min(300, max(50, newValue)) }; notifyCosmeticChange() }
    }

    var textAlignment: ThemeTextAlignment {
        get { currentTheme.textAlignment }
        set { mutateCurrentTheme { $0.textAlignment = newValue }; notifyCosmeticChange() }
    }

    var hyphenate: Bool {
        get { currentTheme.hyphenate }
        set { mutateCurrentTheme { $0.hyphenate = newValue }; notifyCosmeticChange() }
    }

    var paragraphSpacing: Double {
        get { currentTheme.paragraphSpacing }
        set { mutateCurrentTheme { $0.paragraphSpacing = min(3, max(0, newValue)) }; notifyCosmeticChange() }
    }

    /// `nil` preserves the book's own `text-indent`; a number applies a
    /// reader-owned first-line indent in ems.
    var paragraphIndent: Double? {
        get { currentTheme.paragraphIndent }
        set {
            mutateCurrentTheme { $0.paragraphIndent = newValue.map(ReaderCSSSanitizer.paragraphIndent) }
            notifyCosmeticChange()
        }
    }

    var boldWeight: ThemeBoldWeight {
        get { currentTheme.boldWeight }
        set { mutateCurrentTheme { $0.boldWeight = newValue }; notifyCosmeticChange() }
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

    /// Strips leading space/tab runs immediately inside paragraph-like elements, for
    /// books that fake first-line indentation with literal whitespace. Structural (it
    /// changes what HTML gets built), not cosmetic.
    var removeParagraphIndents: Bool {
        get { defaults.bool(forKey: "readerRemoveParagraphIndents") }
        set { defaults.set(newValue, forKey: "readerRemoveParagraphIndents"); notifyStructuralChange() }
    }

    /// Collapses empty spacer paragraphs (a `<p>` holding only `&nbsp;`, whitespace or `<br>`) to zero
    /// height, so Paragraph Spacing is the only gap between paragraphs. Structural for the same
    /// reason as `removeParagraphIndents`: it changes the HTML that gets built.
    var collapseSpacerParagraphs: Bool {
        get { defaults.bool(forKey: "readerCollapseSpacerParagraphs") }
        set { defaults.set(newValue, forKey: "readerCollapseSpacerParagraphs"); notifyStructuralChange() }
    }

    /// Hides embedded images in EPUB reading content while keeping their source
    /// markup intact. Structural because both reading-mode documents are rebuilt
    /// when this preference changes; turning it off reveals the original images.
    var hideImages: Bool {
        get { defaults.bool(forKey: "readerHideImages") }
        set { defaults.set(newValue, forKey: "readerHideImages"); notifyStructuralChange() }
    }

    /// Starts new EPUB sessions after an explicitly identified cover landmark.
    /// Existing saved positions take precedence.
    var skipCoverWhenOpening: Bool {
        get { defaults.bool(forKey: "readerSkipCoverWhenOpening") }
        set { defaults.set(newValue, forKey: "readerSkipCoverWhenOpening"); notifyStructuralChange() }
    }

    // MARK: Pagination

    /// Global default for which mode a reader window opens in. Deliberately not
    /// per-book — every window opens in whatever the current global default is,
    /// not read from or written to HistoryEntry.
    var defaultReadingMode: ReadingMode {
        get { ReadingMode(rawValue: defaults.integer(forKey: "readerDefaultReadingMode")) ?? .scroll }
        set { defaults.set(newValue.rawValue, forKey: "readerDefaultReadingMode"); notifyStructuralChange() }
    }

    var autoScrollSpeed: Double {
        get {
            defaults.object(forKey: "readerAutoScrollSpeed") == nil
                ? 60 : defaults.double(forKey: "readerAutoScrollSpeed")
        }
        set { defaults.set(min(1200, max(10, newValue)), forKey: "readerAutoScrollSpeed"); notifyChange() }
    }

    var adjustScrollSpeedWhilePaging: Bool {
        get {
            defaults.object(forKey: "readerAdjustScrollSpeedWhilePaging") == nil
                ? true : defaults.bool(forKey: "readerAdjustScrollSpeedWhilePaging")
        }
        set { defaults.set(newValue, forKey: "readerAdjustScrollSpeedWhilePaging"); notifyChange() }
    }

    var speechVoiceIdentifier: String? {
        get { defaults.string(forKey: "readerSpeechVoiceIdentifier") }
        set {
            if let newValue {
                defaults.set(newValue, forKey: "readerSpeechVoiceIdentifier")
            } else {
                defaults.removeObject(forKey: "readerSpeechVoiceIdentifier")
            }
            notifyChange()
        }
    }

    var speechRate: Float {
        get {
            let val = defaults.float(forKey: "readerSpeechRate")
            return val > 0 ? val : AVSpeechUtteranceDefaultSpeechRate
        }
        set {
            defaults.set(newValue, forKey: "readerSpeechRate")
            notifyChange()
        }
    }

    var colsPerScreen: ColsPerScreen {
        get { ColsPerScreen(rawValue: defaults.integer(forKey: "readerColsPerScreen")) ?? .one }
        set { defaults.set(newValue.rawValue, forKey: "readerColsPerScreen"); notifyStructuralChange() }
    }

    /// Whether opening a new book creates a new window or a new tab on the
    /// frontmost reader window. See NewBookOpensIn's doc comment.
    var newBookOpensIn: NewBookOpensIn {
        get { NewBookOpensIn(rawValue: defaults.integer(forKey: "readerNewBookOpensIn")) ?? .newWindow }
        set { defaults.set(newValue.rawValue, forKey: "readerNewBookOpensIn"); notifyChange() }
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

    /// Per-theme now -- see Theme.maxWidth's doc comment. Reading-column max
    /// width in points. Default (700) matches the constant
    /// EPUBParser.paginatedColumnCSS previously hardcoded.
    var maxWidth: Int {
        get { currentTheme.maxWidth }
        set { mutateCurrentTheme { $0.maxWidth = max(320, min(1400, newValue)) }; notifyStructuralChange() }
    }

    /// Per-theme now -- see Theme.paddingH's doc comment. Horizontal reading
    /// margin in points. Default (24) matches the constant previously
    /// hardcoded in EPUBParser.paginatedColumnCSS.
    var paddingH: Int {
        get { currentTheme.paddingH }
        set { mutateCurrentTheme { $0.paddingH = max(0, min(120, newValue)) }; notifyStructuralChange() }
    }

    /// Per-theme now -- see Theme.paddingV's doc comment. Vertical reading
    /// margin in points (paginated mode only — scroll mode's vertical spacing
    /// comes from #content's own fixed top/bottom padding). Default (24)
    /// matches the constant previously hardcoded in EPUBParser.paginatedColumnCSS.
    var paddingV: Int {
        get { currentTheme.paddingV }
        set { mutateCurrentTheme { $0.paddingV = max(0, min(120, newValue)) }; notifyStructuralChange() }
    }

    /// Applies a mutation to the currently active theme and persists it.
    /// Shared by every per-theme typography accessor above.
    private func mutateCurrentTheme(_ mutate: (inout Theme) -> Void) {
        var list = themes
        guard let idx = list.firstIndex(where: { $0.id == currentThemeID }) else { return }
        mutate(&list[idx])
        themes = list
    }

    /// Whether in-book links are clickable -- both internal cross-references
    /// (footnotes, TOC entries) and external http/https links, which
    /// ReaderViewController's WKNavigationDelegate intercepts and opens in the
    /// user's default browser via NSWorkspace.shared.open(_:), not inside the
    /// reader itself. On by default: most readers expect tapping a link in a
    /// book to actually go somewhere, and silently no-oping every link
    /// (including ones the author intended to open externally) was a more
    /// surprising default than an occasional accidental click on an internal
    /// cross-reference. Purely a CSS pointer-events toggle, so this is
    /// cosmetic, not structural.
    var allowReaderLinkClicks: Bool {
        get {
            defaults.object(forKey: "readerAllowLinkClicks") == nil
                ? true : defaults.bool(forKey: "readerAllowLinkClicks")
        }
        set { defaults.set(newValue, forKey: "readerAllowLinkClicks"); notifyCosmeticChange() }
    }

    /// Whether `code` and `pre` text uses the theme font (true, the default) or the monospace
    /// stack (false). Global rather than per-theme, like `allowReaderLinkClicks`. Purely a CSS
    /// variable, so cosmetic.
    var useThemeFontForCode: Bool {
        get {
            defaults.object(forKey: "readerUseThemeFontForCode") == nil
                ? true : defaults.bool(forKey: "readerUseThemeFontForCode")
        }
        set { defaults.set(newValue, forKey: "readerUseThemeFontForCode"); notifyCosmeticChange() }
    }

    /// Whether the app follows the system's light/dark setting or overrides
    /// it. Setting this both persists the choice and immediately re-applies
    /// it to NSApp -- `systemIsDark`/`effectiveColorSet` above don't need any
    /// changes since they read NSApp.effectiveAppearance, which itself
    /// reflects whatever NSApp.appearance is set to below.
    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearanceMode")
            Self.applyAppearanceOverride(newValue)
            notifyCosmeticChange()
        }
    }

    /// Pushes the given mode onto NSApp. Called both from the appearanceMode
    /// setter above and once at launch (see AppDelegate) so a persisted
    /// override is already in effect before the first window appears.
    static func applyAppearanceOverride(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Reset to defaults (Appearance tab)

    /// The typography a freshly-created custom theme gets (see
    /// SettingsWindowController.addThemeClicked's fallback when there's no
    /// base theme to copy from) -- also what Reset to Defaults restores every
    /// non-default theme to, since there's no per-custom-theme "default" to
    /// go back to otherwise.
    private static let customThemeDefaultFontFamily = FontPresets.defaultStack
    private static let customThemeDefaultFontSizePercent = 100
    private static let customThemeDefaultLineHeight = 1.6
    private static let customThemeDefaultMaxWidth = 700
    private static let customThemeDefaultPaddingH = 24
    private static let customThemeDefaultPaddingV = 24

    /// True only when at least one theme differs from its default (seed
    /// values for the three default themes, the shared custom-theme baseline
    /// for every other theme), one of the three default themes is missing
    /// entirely (deleted before deleteTheme() protected them), or the global
    /// link-clicks flag is set -- mirrors Ambrosia's `isReaderCustomized`, so
    /// the "Reset to Defaults" button is inert rather than an always-live
    /// destructive action.
    var isReaderCustomized: Bool {
        let list = themes
        if allowReaderLinkClicks != true { return true }
        if useThemeFontForCode != true { return true }
        let existingSeedKeys = Set(list.compactMap(\.seedKey))
        if Self.seedThemes.contains(where: { !existingSeedKeys.contains($0.seedKey ?? "") }) { return true }
        for theme in list {
            if theme.isDefault {
                guard let seed = Self.seedThemes.first(where: { $0.seedKey == theme.seedKey }) else { return true }
                if theme.name != seed.name || theme.light != seed.light || theme.dark != seed.dark
                    || theme.fontFamily != seed.fontFamily
                    || theme.fontSizePercent != 100
                    || theme.lineHeight != 1.6
                    || theme.maxWidth != 700
                    || theme.paddingH != 24
                    || theme.paddingV != 24
                    || theme.textAlignment != .book
                    || theme.hyphenate
                    || theme.paragraphSpacing != 1.0 || theme.paragraphIndent != nil || theme.boldWeight != .book
                {
                    return true
                }
            } else {
                if theme.fontFamily != Self.customThemeDefaultFontFamily
                    || theme.fontSizePercent != Self.customThemeDefaultFontSizePercent
                    || theme.lineHeight != Self.customThemeDefaultLineHeight
                    || theme.maxWidth != Self.customThemeDefaultMaxWidth
                    || theme.paddingH != Self.customThemeDefaultPaddingH
                    || theme.paddingV != Self.customThemeDefaultPaddingV
                    || theme.textAlignment != .book
                    || theme.hyphenate
                    || theme.paragraphSpacing != 1.0 || theme.paragraphIndent != nil || theme.boldWeight != .book
                {
                    return true
                }
            }
        }
        return false
    }

    /// Resets every theme to its default, not just the currently selected
    /// one: each of the three default themes (Original/Quiet/Paper) goes back
    /// to its own seeded colors/font/size/line-height/margins -- re-adding
    /// any of the three that had been deleted before deleteTheme() protected
    /// them -- and every custom theme keeps its own name/colors but has its
    /// typography reset to the shared new-theme baseline. Custom themes are
    /// never re-created if deleted. Also resets the global link-clicks flag.
    /// Selection itself is left alone -- whichever theme was active stays
    /// active, just with its settings restored (unless it no longer exists,
    /// e.g. it was one of the just-restored defaults, in which case it's
    /// simply added back rather than reselected).
    func resetReaderToDefaults() {
        var list = themes

        // Restore any of the three default themes (Original/Quiet/Paper) that
        // got deleted before deleteTheme() protected them -- re-added as fresh
        // copies, in seed order, ahead of whatever's already there. Existing
        // custom themes are left alone, whether or not they're also missing
        // one of their own.
        let existingSeedKeys = Set(list.compactMap(\.seedKey))
        let missingSeeds = Self.seedThemes.filter { !existingSeedKeys.contains($0.seedKey ?? "") }
        if !missingSeeds.isEmpty {
            list.insert(contentsOf: missingSeeds, at: 0)
        }

        let resetList: [Theme] = list.map { theme in
            var updatedTheme = theme
            if theme.isDefault {
                // Matched by seedKey, not by position or name: position broke when a
                // default was deleted, and name broke when the user renamed one.
                if let seed = Self.seedThemes.first(where: { $0.seedKey == theme.seedKey }) {
                    updatedTheme.name = seed.name
                    updatedTheme.light = seed.light
                    updatedTheme.dark = seed.dark
                    updatedTheme.fontFamily = seed.fontFamily
                }
            } else {
                updatedTheme.fontFamily = Self.customThemeDefaultFontFamily
            }
            updatedTheme.fontSizePercent = theme.isDefault ? 100 : Self.customThemeDefaultFontSizePercent
            updatedTheme.lineHeight = theme.isDefault ? 1.6 : Self.customThemeDefaultLineHeight
            updatedTheme.maxWidth = theme.isDefault ? 700 : Self.customThemeDefaultMaxWidth
            updatedTheme.paddingH = theme.isDefault ? 24 : Self.customThemeDefaultPaddingH
            updatedTheme.paddingV = theme.isDefault ? 24 : Self.customThemeDefaultPaddingV
            updatedTheme.textAlignment = .book
            updatedTheme.hyphenate = false
            updatedTheme.paragraphSpacing = 1.0
            updatedTheme.paragraphIndent = nil
            updatedTheme.boldWeight = .book
            return updatedTheme
        }
        themes = resetList
        allowReaderLinkClicks = true
        useThemeFontForCode = true
    }

    /// Resets every settings tab, not just Appearance's themes: General's
    /// behaviour flags, the reader/theme settings resetReaderToDefaults()
    /// already covers, and every keyboard shortcut back to its
    /// RebindableAction.defaultBinding. Backs the "Reset All to Defaults"
    /// button on the General tab.
    func resetAllToDefaults() {
        formatFirstChapter = false
        removeParagraphIndents = false
        collapseSpacerParagraphs = false
        hideImages = false
        skipCoverWhenOpening = false
        autoScrollSpeed = 60
        adjustScrollSpeedWhilePaging = true
        speechVoiceIdentifier = nil
        speechRate = AVSpeechUtteranceDefaultSpeechRate
        defaultReadingMode = .scroll
        colsPerScreen = .one
        newBookOpensIn = .newWindow
        resetReaderToDefaults()
        keyBindings = Dictionary(uniqueKeysWithValues: RebindableAction.allCases.map { ($0, $0.defaultBinding) })
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
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Convert a CSS hex string to NSColor
    static func color(fromCSS hex: String) -> NSColor {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits = String(digits.dropFirst()) }
        guard digits.count == 6, let val = UInt32(digits, radix: 16) else { return .black }
        return NSColor(
            red: CGFloat((val >> 16) & 0xff) / 255,
            green: CGFloat((val >> 8) & 0xff) / 255,
            blue: CGFloat(val & 0xff) / 255,
            alpha: 1
        )
    }
}
