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

/// A named font-family CSS stack offered as a quick-recall choice for the reader font override
/// (ported from Ambrosia's `ReaderPreferences.FontPreset`).
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

    // Notification batching: while `batchDepth > 0`, notify* calls only record what happened and one
    // notification set is posted when the outermost batch ends. A structural change supersedes a
    // cosmetic one, because a structural reload rebuilds the cosmetics anyway.
    private var batchDepth = 0
    private var pendingGeneral = false
    private var pendingCosmetic = false
    private var pendingStructural = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let migratedKey = "readerFanficPrefaceMigrated"
        if !defaults.bool(forKey: migratedKey) {
            defaults.set(false, forKey: "readerFanficPreface")
            defaults.set(true, forKey: migratedKey)
        }
    }

    // MARK: Reader overrides

    private static let overridesKey = "readerOverrides.v1"

    /// The user's overrides, sanitized. Every field is optional; nil means "the theme decides".
    /// Stored as one JSON value. Keys written by earlier builds (readerFontOverride,
    /// readerFontSizePercent, ...) are no longer read.
    var readerOverrides: ReaderOverrides {
        guard let data = defaults.data(forKey: Self.overridesKey),
              let decoded = try? JSONDecoder().decode(ReaderOverrides.self, from: data)
        else { return .none }
        return decoded.sanitized()
    }

    /// The single write path for overrides: reads, applies `change`, sanitizes, persists once and
    /// posts one notification. Geometry changes (max width, margins) are structural because they are
    /// baked into the paginated HTML; everything else is cosmetic. No-ops post nothing.
    func updateReaderOverrides(_ change: (inout ReaderOverrides) -> Void) {
        let old = readerOverrides
        var updated = old
        change(&updated)
        updated = updated.sanitized()
        guard updated != old else { return }
        if updated == .none {
            defaults.removeObject(forKey: Self.overridesKey)
        } else if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.overridesKey)
        }
        if updated.changesGeometry(from: old) { notifyStructuralChange() } else { notifyCosmeticChange() }
    }

    var hasReaderOverrides: Bool { readerOverrides != .none }

    func clearReaderOverrides() {
        updateReaderOverrides { $0 = .none }
    }

    /// True when NSApp's effective appearance is dark. Read fresh each time, since the system can
    /// flip appearance at any moment. Safe when there is no NSApp (unit tests).
    private var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The selected theme's token colors for the current appearance, or the baseline colors.
    var effectiveColorSet: ReaderColorSet {
        let skin = SkinStore.shared.skin(id: readerSkinID)
        let tokens = systemIsDark ? (skin?.dark ?? skin?.light) : skin?.light
        return ReaderColorSet(
            background: tokens?.background ?? ReaderBaseline.background,
            text: tokens?.ink ?? ReaderBaseline.text,
            link: tokens?.link ?? ReaderBaseline.link)
    }

    // MARK: Compatibility accessors
    //
    // Thin forwarders so the existing Appearance pane keeps compiling until it is rebuilt. A value
    // equal to the baseline is stored as nil ("theme decides"), which keeps `hasReaderOverrides`
    // honest. Color setters write both light and dark.

    var lineHeight: Double {
        get { readerOverrides.lineHeight ?? ReaderBaseline.lineHeight }
        set { updateReaderOverrides { $0.lineHeight = newValue == ReaderBaseline.lineHeight ? nil : newValue } }
    }

    var fontSizePercent: Int {
        get { readerOverrides.fontSizePercent ?? ReaderBaseline.fontSizePercent }
        set { updateReaderOverrides { $0.fontSizePercent = newValue == ReaderBaseline.fontSizePercent ? nil : newValue } }
    }

    /// Reader font override. Empty means the theme (or the default stack) decides.
    var readerFontOverride: String {
        get { readerOverrides.bodyFont ?? "" }
        set { updateReaderOverrides { $0.bodyFont = newValue.isEmpty ? nil : newValue } }
    }

    var effectiveReaderFontFamily: String {
        readerOverrides.bodyFont ?? FontPresets.defaultStack
    }

    var readerBackgroundOverride: String {
        get { readerOverrides.colors(isDark: systemIsDark).background ?? "" }
        set {
            let value = newValue.isEmpty ? nil : newValue
            updateReaderOverrides { $0.light.background = value; $0.dark.background = value }
        }
    }

    var readerInkOverride: String {
        get { readerOverrides.colors(isDark: systemIsDark).ink ?? "" }
        set {
            let value = newValue.isEmpty ? nil : newValue
            updateReaderOverrides { $0.light.ink = value; $0.dark.ink = value }
        }
    }

    var readerLinkOverride: String {
        get { readerOverrides.colors(isDark: systemIsDark).link ?? "" }
        set {
            let value = newValue.isEmpty ? nil : newValue
            updateReaderOverrides { $0.light.link = value; $0.dark.link = value }
        }
    }

    /// Replaces recognized fanfiction front matter with the generated preface. Structural because
    /// rendered spine content and offsets change.
    var fanficPreface: Bool {
        get { defaults.bool(forKey: "readerFanficPreface") }
        set { defaults.set(newValue, forKey: "readerFanficPreface"); notifyStructuralChange() }
    }

    var readerSkinID: String {
        get { defaults.string(forKey: "readerSkinID") ?? "com.honeycrisp.original" }
        set { defaults.set(newValue, forKey: "readerSkinID"); notifyStructuralChange() }
    }

    func validateReaderSkinSelection() {
        if SkinStore.shared.skin(id: readerSkinID) == nil {
            defaults.set("com.honeycrisp.original", forKey: "readerSkinID")
        }
    }

    /// Strips leading space/tab runs immediately inside paragraph-like elements, for
    /// books that fake first-line indentation with literal whitespace. Structural (it
    /// changes what HTML gets built), not cosmetic. It does not write `paragraphIndent`: when it is
    /// on and the user has not chosen an indent, resolution uses 0 (see ReaderCosmeticSettings.resolve).
    var removeParagraphIndents: Bool {
        get { defaults.bool(forKey: "readerRemoveParagraphIndents") }
        set {
            defaults.set(newValue, forKey: "readerRemoveParagraphIndents")
            notifyStructuralChange()
        }
    }

    var paragraphIndent: Double {
        get { readerOverrides.paragraphIndent ?? ReaderBaseline.paragraphIndent }
        set { updateReaderOverrides { $0.paragraphIndent = newValue == ReaderBaseline.paragraphIndent ? nil : newValue } }
    }

    var paragraphSpacing: Double {
        get { readerOverrides.paragraphSpacing ?? ReaderBaseline.paragraphSpacing }
        set { updateReaderOverrides { $0.paragraphSpacing = newValue == ReaderBaseline.paragraphSpacing ? nil : newValue } }
    }

    var justifyReaderText: Bool {
        get { readerOverrides.justify ?? ReaderBaseline.justify }
        set { updateReaderOverrides { $0.justify = newValue ? true : nil } }
    }

    var hyphenateReaderText: Bool {
        get { readerOverrides.hyphenate ?? ReaderBaseline.hyphenate }
        set { updateReaderOverrides { $0.hyphenate = newValue ? true : nil } }
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

    /// Reading-column max width in points. Default (700) matches the constant
    /// EPUBParser.paginatedColumnCSS previously hardcoded.
    var maxWidth: Int {
        get { readerOverrides.maxWidth ?? ReaderBaseline.maxWidth }
        set { updateReaderOverrides { $0.maxWidth = newValue == ReaderBaseline.maxWidth ? nil : newValue } }
    }

    /// Horizontal reading margin in points.
    var paddingH: Int {
        get { readerOverrides.paddingH ?? ReaderBaseline.paddingH }
        set { updateReaderOverrides { $0.paddingH = newValue == ReaderBaseline.paddingH ? nil : newValue } }
    }

    /// Vertical reading margin in points (paginated mode only; scroll mode's vertical spacing comes
    /// from #content's own fixed top/bottom padding).
    var paddingV: Int {
        get { readerOverrides.paddingV ?? ReaderBaseline.paddingV }
        set { updateReaderOverrides { $0.paddingV = newValue == ReaderBaseline.paddingV ? nil : newValue } }
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

    // MARK: - Reset to defaults

    /// True when anything the Appearance tab controls differs from its default.
    var isReaderCustomized: Bool {
        hasReaderOverrides || removeParagraphIndents || readerSkinID != "com.honeycrisp.original" || !allowReaderLinkClicks
    }

    /// Restores the reader's appearance to defaults: Original theme, no overrides, indents kept,
    /// link clicks on. Posts one notification set no matter how many values change.
    func resetReaderToDefaults() {
        performBatch {
            readerSkinID = "com.honeycrisp.original"
            clearReaderOverrides()
            removeParagraphIndents = false
            allowReaderLinkClicks = true
        }
    }

    /// Resets every settings tab: General's behaviour flags, the reader appearance settings, and
    /// every keyboard shortcut back to its RebindableAction.defaultBinding. Backs the
    /// "Reset All to Defaults" button on the General tab.
    func resetAllToDefaults() {
        performBatch {
            fanficPreface = false
            hideImages = false
            skipCoverWhenOpening = false
            autoScrollSpeed = 60
            adjustScrollSpeedWhilePaging = true
            speechVoiceIdentifier = nil
            defaultReadingMode = .scroll
            colsPerScreen = .one
            newBookOpensIn = .newWindow
            resetReaderToDefaults()
        }
        keyBindings = Dictionary(uniqueKeysWithValues: RebindableAction.allCases.map { ($0, $0.defaultBinding) })
    }

    // MARK: -

    /// Runs `body` and posts one notification set at the end, however many values it changed.
    private func performBatch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        let structural = pendingStructural
        let cosmetic = pendingCosmetic
        let general = pendingGeneral
        pendingStructural = false
        pendingCosmetic = false
        pendingGeneral = false
        if structural {
            NotificationCenter.default.post(name: .readerStructuralSettingsChanged, object: nil)
        } else if cosmetic {
            NotificationCenter.default.post(name: .readerCosmeticSettingsChanged, object: nil)
        }
        if structural || cosmetic || general {
            NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
        }
    }

    private func notifyChange() {
        if batchDepth > 0 { pendingGeneral = true; return }
        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
    }

    /// Cosmetic changes also post the general notification, so anything (like
    /// HistorySettingsViewController) still watching the old generic notification
    /// keeps working unchanged.
    private func notifyCosmeticChange() {
        if batchDepth > 0 { pendingCosmetic = true; pendingGeneral = true; return }
        NotificationCenter.default.post(name: .readerCosmeticSettingsChanged, object: nil)
        notifyChange()
    }

    private func notifyStructuralChange() {
        if batchDepth > 0 { pendingStructural = true; pendingGeneral = true; return }
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
