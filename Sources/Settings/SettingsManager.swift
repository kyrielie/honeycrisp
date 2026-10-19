// SettingsManager.swift
//
// CHANGES vs original:
//  • showTitleInMenuBar property REMOVED — title is always shown in the toolbar
//  • the legacy formatFirstChapter preference migrates once to fanficPreface

// swiftlint:disable file_length
import AppKit

/// Overrides the window chrome/system-level light-or-dark appearance.
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
    // True only for the three seeded themes (Original/Quiet/Paper). Drives
    // two things: deleteTheme(_:) refuses to remove these regardless of how
    // many themes exist, and resetReaderToDefaults() knows to restore these
    // from `seedThemes` rather than the shared "new custom theme" baseline.
    // Defaults to false so existing persisted (pre-flag) themes -- which are
    // all user-created by definition, since the seed themes are re-tagged
    // by id below -- decode as non-default.
    var isDefault: Bool

    init(
        id: UUID = UUID(), name: String, light: ThemeColorSet, dark: ThemeColorSet,
        fontFamily: String = FontPresets.defaultStack,
        fontSizePercent: Int = 100,
        lineHeight: Double = 1.6,
        maxWidth: Int = 700,
        paddingH: Int = 24,
        paddingV: Int = 24,
        isDefault: Bool = false
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
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, light, dark, fontFamily, fontSizePercent, lineHeight, maxWidth, paddingH, paddingV, isDefault
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
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
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

    private let defaults = UserDefaults.standard
    private var isMigratingReaderOverrides = false

    private init() {
        let migratedKey = "readerFanficPrefaceMigrated"
        if !defaults.bool(forKey: migratedKey) {
            defaults.set(false, forKey: "readerFanficPreface")
            defaults.set(true, forKey: migratedKey)
        }
    }

    // MARK: Font

    /// Compatibility accessor for existing reader CSS call sites.
    var fontFamily: String {
        get { effectiveReaderFontFamily }
        set { readerFontOverride = newValue }
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
            isDefault: true),
        Theme(
            name: "Quiet",
            light: ThemeColorSet(background: "#2c2c2c", text: "#8a8a8a", link: "#7fb2e8"),
            dark: ThemeColorSet(background: "#1c1c1e", text: "#8a8a8a", link: "#7fb2e8"),
            fontFamily: FontPresets.all.first { $0.id == "iowan" }!.cssStack,
            isDefault: true),
        Theme(
            name: "Paper",
            light: ThemeColorSet(background: "#f4ecd8", text: "#433422", link: "#8a5a2b"),
            dark: ThemeColorSet(background: "#2b2216", text: "#d8c9a8", link: "#c99a55"),
            fontFamily: FontPresets.all.first { $0.id == "georgia" }!.cssStack,
            isDefault: true),
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

    /// JSON-array-in-UserDefaults, same pattern as HistoryManager.entries. Migrates
    /// the old fixed ReaderTheme selection + single custom color pair into an
    /// equivalent seeded theme the first time this is read post-upgrade, so
    /// existing users don't lose their current look.
    var themes: [Theme] {
        get {
            if defaults.bool(forKey: "readerOverridesMigrated") { return Self.seedThemes }
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
                    let migrated = Self.backfillIsDefault(decoded)
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
            if defaults.bool(forKey: "readerOverridesMigrated") { return }
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

    private func migrateStoredThemesToReaderOverridesIfNeeded() {
        guard !isMigratingReaderOverrides,
              !defaults.bool(forKey: "readerOverridesMigrated"),
              defaults.data(forKey: "readerThemes") != nil
        else { return }
        isMigratingReaderOverrides = true
        defer { isMigratingReaderOverrides = false }
        // Go through the legacy getter so schemas predating per-theme typography
        // first receive their old global values before we convert them.
        let decoded = themes
        guard !decoded.isEmpty else { return }
        let id = defaults.string(forKey: "readerCurrentThemeID").flatMap(UUID.init(uuidString:))
        let active = decoded.first(where: { $0.id == id }) ?? decoded[0]
        let font = active.fontFamily == Self.seedThemes.first(where: { $0.name == active.name })?.fontFamily ? "" : active.fontFamily
        defaults.set(font.isEmpty ? "" : ReaderCSSSanitizer.fontFamily(font, fallback: ""), forKey: "readerFontOverride")
        defaults.set(min(300, max(50, active.fontSizePercent)), forKey: "readerFontSizePercent")
        defaults.set(ReaderCSSSanitizer.lineHeight(active.lineHeight), forKey: "readerLineHeight")
        defaults.set(min(1200, max(320, active.maxWidth)), forKey: "readerMaxWidth")
        defaults.set(min(100, max(0, active.paddingH)), forKey: "readerPaddingH")
        defaults.set(min(100, max(0, active.paddingV)), forKey: "readerPaddingV")
        let isDefaultColors = Self.seedThemes.first(where: { $0.name == active.name }).map { active.light == $0.light && active.dark == $0.dark } ?? false
        if !isDefaultColors {
            let colors = systemIsDark ? active.dark : active.light
            defaults.set(ReaderCSSSanitizer.hexColor(colors.background, fallback: ""), forKey: "readerBackgroundOverride")
            defaults.set(ReaderCSSSanitizer.hexColor(colors.text, fallback: ""), forKey: "readerInkOverride")
            defaults.set(ReaderCSSSanitizer.hexColor(colors.link, fallback: ""), forKey: "readerLinkOverride")
        }
        defaults.set(true, forKey: "readerOverridesMigrated")
        defaults.removeObject(forKey: "readerThemes")
        defaults.removeObject(forKey: "readerCurrentThemeID")
        defaults.removeObject(forKey: "readerTheme")
        defaults.removeObject(forKey: "readerCustomBg")
        defaults.removeObject(forKey: "readerCustomText")
        NotificationCenter.default.post(name: .readerCosmeticSettingsChanged, object: nil)
        notifyChange()
    }

    /// Which theme is active, by id. Falls back to the first theme (and repairs
    /// the stored id) if the previously-selected theme was deleted.
    var currentThemeID: UUID { Self.seedThemes[0].id }

    var currentTheme: Theme { Self.seedThemes[0] }

    /// True when NSApp's effective appearance is dark — used to pick which of a
    /// theme's two ThemeColorSets is currently in effect. Read fresh each time
    /// rather than cached, since the system can flip appearance at any moment.
    private var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The selected skin's token colors for the current system appearance.
    var effectiveColorSet: ThemeColorSet {
        migrateStoredThemesToReaderOverridesIfNeeded()
        let skin = SkinStore.shared.skin(id: defaults.string(forKey: "readerSkinID") ?? "com.honeycrisp.original")
        let tokens = systemIsDark ? (skin?.dark ?? skin?.light) : skin?.light
        return ThemeColorSet(background: tokens?.background ?? "#ffffff", text: tokens?.ink ?? "#000000", link: tokens?.link ?? "#0068da")
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

    // MARK: Line height

    /// Global reading line-height override.
    var lineHeight: Double {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.object(forKey: "readerLineHeight").map { ($0 as? Double) ?? 1.6 } ?? 1.6
        }
        set { defaults.set(ReaderCSSSanitizer.lineHeight(newValue), forKey: "readerLineHeight"); notifyCosmeticChange() }
    }

    // MARK: Font size

    /// Global reading font-size override.
    var fontSizePercent: Int {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            if let value = defaults.object(forKey: "readerFontSizePercent") as? Int { return value }
            let legacy = defaults.integer(forKey: "readerFontSize")
            return legacy == 0 ? 100 : legacy
        }
        set { defaults.set(min(300, max(50, newValue)), forKey: "readerFontSizePercent"); notifyCosmeticChange() }
    }

    // MARK: Behaviour flags

    /// Reader-only font override. Empty means use the selected skin's font.
    var readerFontOverride: String {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.string(forKey: "readerFontOverride") ?? ""
        }
        set {
            let value = newValue.isEmpty ? "" : ReaderCSSSanitizer.fontFamily(newValue, fallback: "")
            defaults.set(value, forKey: "readerFontOverride")
            notifyCosmeticChange()
        }
    }

    var effectiveReaderFontFamily: String {
        if !readerFontOverride.isEmpty { return readerFontOverride }
        return SkinStore.shared.skin(id: defaults.string(forKey: "readerSkinID") ?? "com.honeycrisp.original")?.family
            ?? FontPresets.defaultStack
    }

    private var hasMigratedReaderOverrides: Bool {
        get { defaults.bool(forKey: "readerOverridesMigrated") }
        set { defaults.set(newValue, forKey: "readerOverridesMigrated") }
    }

    func migrateReaderOverridesIfNeeded() {
        migrateStoredThemesToReaderOverridesIfNeeded()
    }

    var readerBackgroundOverride: String {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.string(forKey: "readerBackgroundOverride") ?? ""
        }
        set {
            let value = newValue.isEmpty ? "" : ReaderCSSSanitizer.hexColor(newValue, fallback: "")
            defaults.set(value, forKey: "readerBackgroundOverride")
            notifyCosmeticChange()
        }
    }

    var readerInkOverride: String {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.string(forKey: "readerInkOverride") ?? ""
        }
        set {
            let value = newValue.isEmpty ? "" : ReaderCSSSanitizer.hexColor(newValue, fallback: "")
            defaults.set(value, forKey: "readerInkOverride")
            notifyCosmeticChange()
        }
    }

    var readerLinkOverride: String {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.string(forKey: "readerLinkOverride") ?? ""
        }
        set {
            let value = newValue.isEmpty ? "" : ReaderCSSSanitizer.hexColor(newValue, fallback: "")
            defaults.set(value, forKey: "readerLinkOverride")
            notifyCosmeticChange()
        }
    }

    var hasReaderColorOverrides: Bool {
        !readerBackgroundOverride.isEmpty || !readerInkOverride.isEmpty || !readerLinkOverride.isEmpty
    }

    var hasReaderOverrides: Bool {
        hasReaderColorOverrides || !readerFontOverride.isEmpty || fontSizePercent != 100 || lineHeight != 1.6
            || maxWidth != 700 || paddingH != 24 || paddingV != 24 || paragraphIndent != 0.3 || paragraphSpacing != 0.5
            || justifyReaderText || hyphenateReaderText
    }

    func clearReaderOverrides() {
        migrateStoredThemesToReaderOverridesIfNeeded()
        ["readerFontOverride", "readerBackgroundOverride", "readerInkOverride", "readerLinkOverride"].forEach(defaults.removeObject(forKey:))
        fontSizePercent = 100
        lineHeight = 1.6
        maxWidth = 700
        paddingH = 24
        paddingV = 24
        paragraphIndent = 0.3
        paragraphSpacing = 0.5
        justifyReaderText = false
        hyphenateReaderText = false
        defaults.set(true, forKey: "readerOverridesMigrated")
        notifyCosmeticChange()
    }

    /// Replaces recognized fanfiction front matter with the generated preface. Structural because
    /// rendered spine content and offsets change.
    var fanficPreface: Bool {
        get { defaults.bool(forKey: "readerFanficPreface") }
        set { defaults.set(newValue, forKey: "readerFanficPreface"); notifyStructuralChange() }
    }

    var readerSkinID: String {
        get {
            if let existing = defaults.string(forKey: "readerSkinID") { return existing }
            let id = migrateLegacyReaderSkin()
            migrateReaderOverridesIfNeeded()
            defaults.set(id, forKey: "readerSkinID")
            return id
        }
        set { defaults.set(newValue, forKey: "readerSkinID"); notifyStructuralChange() }
    }

    func validateReaderSkinSelection() {
        if SkinStore.shared.skin(id: readerSkinID) == nil {
            defaults.set("com.honeycrisp.original", forKey: "readerSkinID")
        }
    }

    private func migrateLegacyReaderSkin() -> String {
        guard defaults.data(forKey: "readerThemes") != nil else { return "com.honeycrisp.original" }
        let legacy: Theme
        if let data = defaults.data(forKey: "readerThemes"),
           let decoded = try? JSONDecoder().decode([Theme].self, from: data), !decoded.isEmpty {
            let id = defaults.string(forKey: "readerCurrentThemeID").flatMap(UUID.init(uuidString:))
            legacy = decoded.first(where: { $0.id == id }) ?? decoded[0]
        } else { return "com.honeycrisp.original" }
        let name = legacy.name.lowercased()
        switch name {
        case "quiet": return "com.honeycrisp.quiet"
        case "paper": return "com.honeycrisp.paper"
        default:
            if legacy.light.background.lowercased() == "#f4ecd8" { return "com.honeycrisp.paper" }
            if legacy.light.background.lowercased() == "#2c2c2c" { return "com.honeycrisp.quiet" }
            return "com.honeycrisp.original"
        }
    }

    /// Strips leading space/tab runs immediately inside paragraph-like elements, for
    /// books that fake first-line indentation with literal whitespace. Structural (it
    /// changes what HTML gets built), not cosmetic.
    var removeParagraphIndents: Bool {
        get { defaults.bool(forKey: "readerRemoveParagraphIndents") }
        set {
            defaults.set(newValue, forKey: "readerRemoveParagraphIndents")
            if newValue { paragraphIndent = 0 } else { paragraphIndent = 0.3 }
            notifyStructuralChange()
        }
    }

    var paragraphIndent: Double {
        get { defaults.object(forKey: "readerParagraphIndent").map { ($0 as? Double) ?? 0.3 } ?? 0.3 }
        set { defaults.set(min(3, max(0, newValue)), forKey: "readerParagraphIndent"); notifyCosmeticChange() }
    }

    var paragraphSpacing: Double {
        get { defaults.object(forKey: "readerParagraphSpacing").map { ($0 as? Double) ?? 0.5 } ?? 0.5 }
        set { defaults.set(min(3, max(0, newValue)), forKey: "readerParagraphSpacing"); notifyCosmeticChange() }
    }

    var justifyReaderText: Bool {
        get { defaults.bool(forKey: "readerJustifyText") }
        set { defaults.set(newValue, forKey: "readerJustifyText"); notifyCosmeticChange() }
    }

    var hyphenateReaderText: Bool {
        get { defaults.bool(forKey: "readerHyphenateText") }
        set { defaults.set(newValue, forKey: "readerHyphenateText"); notifyCosmeticChange() }
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

    /// Global reading-column max
    /// width in points. Default (700) matches the constant
    /// EPUBParser.paginatedColumnCSS previously hardcoded.
    var maxWidth: Int {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.object(forKey: "readerMaxWidth").map { ($0 as? Int) ?? 700 } ?? 700
        }
        set { defaults.set(ReaderCSSSanitizer.maxWidth(newValue), forKey: "readerMaxWidth"); notifyStructuralChange() }
    }

    /// Global horizontal reading
    /// margin in points. Default (24) matches the constant previously
    /// hardcoded in EPUBParser.paginatedColumnCSS.
    var paddingH: Int {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.object(forKey: "readerPaddingH").map { ($0 as? Int) ?? 24 } ?? 24
        }
        set { defaults.set(ReaderCSSSanitizer.paddingH(newValue), forKey: "readerPaddingH"); notifyStructuralChange() }
    }

    /// Global vertical reading
    /// margin in points (paginated mode only — scroll mode's vertical spacing
    /// comes from #content's own fixed top/bottom padding). Default (24)
    /// matches the constant previously hardcoded in EPUBParser.paginatedColumnCSS.
    var paddingV: Int {
        get {
            migrateStoredThemesToReaderOverridesIfNeeded()
            return defaults.object(forKey: "readerPaddingV").map { ($0 as? Int) ?? 24 } ?? 24
        }
        set { defaults.set(ReaderCSSSanitizer.paddingV(newValue), forKey: "readerPaddingV"); notifyStructuralChange() }
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
    /// True only when at least one theme differs from its default (seed
    /// values for the three default themes, the shared custom-theme baseline
    /// for every other theme), one of the three default themes is missing
    /// entirely (deleted before deleteTheme() protected them), or the global
    /// link-clicks flag is set -- mirrors Ambrosia's `isReaderCustomized`, so
    /// the "Reset to Defaults" button is inert rather than an always-live
    /// destructive action.
    var isReaderCustomized: Bool {
        hasReaderOverrides || readerSkinID != "com.honeycrisp.original" || !allowReaderLinkClicks
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
        readerSkinID = "com.honeycrisp.original"
        clearReaderOverrides()
        readerFontOverride = ""
        fontSizePercent = 100
        lineHeight = 1.6
        maxWidth = 700
        paddingH = 24
        paddingV = 24
        removeParagraphIndents = false
        paragraphIndent = 0.3
        paragraphSpacing = 0.5
        justifyReaderText = false
        hyphenateReaderText = false
        defaults.set(true, forKey: "readerOverridesMigrated")
        defaults.removeObject(forKey: "readerThemes")
        defaults.removeObject(forKey: "readerCurrentThemeID")
        defaults.removeObject(forKey: "readerTheme")
        defaults.removeObject(forKey: "readerCustomBackground")
        defaults.removeObject(forKey: "readerCustomText")
        themes = Self.seedThemes
        allowReaderLinkClicks = true
    }

    /// Resets every settings tab, not just Appearance's themes: General's
    /// behaviour flags, the reader/theme settings resetReaderToDefaults()
    /// already covers, and every keyboard shortcut back to its
    /// RebindableAction.defaultBinding. Backs the "Reset All to Defaults"
    /// button on the General tab.
    func resetAllToDefaults() {
        fanficPreface = false
        removeParagraphIndents = false
        hideImages = false
        skipCoverWhenOpening = false
        autoScrollSpeed = 60
        adjustScrollSpeedWhilePaging = true
        speechVoiceIdentifier = nil
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
