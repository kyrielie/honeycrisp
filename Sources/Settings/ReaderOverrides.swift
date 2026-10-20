// ReaderOverrides.swift
//
// The user's reader appearance overrides as one value. Every field is optional:
// nil means "the selected theme decides", a value means "the user chose this".
// Persisted as a single JSON blob (SettingsManager.readerOverrides), so a change is
// one write and one notification instead of one per property.

import Foundation

/// Colors for a single appearance mode. A nil field falls through to the theme's token.
struct ModeColors: Codable, Equatable {
    var background: String?
    var ink: String?
    var link: String?

    var isEmpty: Bool { background == nil && ink == nil && link == nil }
}

/// A resolved background / text / link triple (CSS `#rrggbb` strings).
struct ReaderColorSet: Equatable {
    var background: String
    var text: String
    var link: String
}

/// Values used when neither the user nor the theme says anything. These match what the reader
/// rendered before overrides became optional.
enum ReaderBaseline {
    static let fontSizePercent = 100
    static let lineHeight = 1.6
    static let maxWidth = 700
    static let paddingH = 24
    static let paddingV = 24
    static let paragraphIndent = 0.3
    static let paragraphSpacing = 0.5
    static let justify = false
    static let hyphenate = false
    static let background = "#ffffff"
    static let text = "#000000"
    static let link = "#0068da"
}

struct ReaderOverrides: Codable, Equatable {
    var version = 1

    // Font roles. Only `bodyFont` is exposed in the UI for now; the others are reserved so adding
    // them later does not change the stored shape (see docs/honeycrisp-skins-and-preface-plan.md 8.4).
    var bodyFont: String?
    var headingFont: String?
    var monospaceFont: String?
    var sansFont: String?

    var fontSizePercent: Int?
    var lineHeight: Double?
    var maxWidth: Int?
    var paddingH: Int?
    var paddingV: Int?
    var paragraphIndent: Double?
    var paragraphSpacing: Double?
    var justify: Bool?
    var hyphenate: Bool?

    var light = ModeColors()
    var dark = ModeColors()

    static let none = ReaderOverrides()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, bodyFont, headingFont, monospaceFont, sansFont
        case fontSizePercent, lineHeight, maxWidth, paddingH, paddingV
        case paragraphIndent, paragraphSpacing, justify, hyphenate, light, dark
    }

    /// Tolerant decoding: a field missing from stored JSON (written by an older or newer build)
    /// reads as "theme decides" instead of failing the whole value.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bodyFont = try values.decodeIfPresent(String.self, forKey: .bodyFont)
        headingFont = try values.decodeIfPresent(String.self, forKey: .headingFont)
        monospaceFont = try values.decodeIfPresent(String.self, forKey: .monospaceFont)
        sansFont = try values.decodeIfPresent(String.self, forKey: .sansFont)
        fontSizePercent = try values.decodeIfPresent(Int.self, forKey: .fontSizePercent)
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight)
        maxWidth = try values.decodeIfPresent(Int.self, forKey: .maxWidth)
        paddingH = try values.decodeIfPresent(Int.self, forKey: .paddingH)
        paddingV = try values.decodeIfPresent(Int.self, forKey: .paddingV)
        paragraphIndent = try values.decodeIfPresent(Double.self, forKey: .paragraphIndent)
        paragraphSpacing = try values.decodeIfPresent(Double.self, forKey: .paragraphSpacing)
        justify = try values.decodeIfPresent(Bool.self, forKey: .justify)
        hyphenate = try values.decodeIfPresent(Bool.self, forKey: .hyphenate)
        light = try values.decodeIfPresent(ModeColors.self, forKey: .light) ?? ModeColors()
        dark = try values.decodeIfPresent(ModeColors.self, forKey: .dark) ?? ModeColors()
    }

    /// True when changing from `old` to `self` alters geometry that is baked into the built HTML
    /// (paginated column CSS), which a live CSS patch cannot retarget.
    func changesGeometry(from old: ReaderOverrides) -> Bool {
        maxWidth != old.maxWidth || paddingH != old.paddingH || paddingV != old.paddingV
    }

    func colors(isDark: Bool) -> ModeColors { isDark ? dark : light }

    /// Returns a copy with every field clamped or dropped by `ReaderCSSSanitizer`, so anything that
    /// reaches CSS is valid even if the stored JSON was edited by hand. Invalid font stacks and
    /// invalid colors become nil (theme decides); numbers are clamped into range.
    func sanitized() -> ReaderOverrides {
        var result = self
        result.version = 1
        result.bodyFont = Self.cleanFont(bodyFont)
        result.headingFont = Self.cleanFont(headingFont)
        result.monospaceFont = Self.cleanFont(monospaceFont)
        result.sansFont = Self.cleanFont(sansFont)
        result.fontSizePercent = fontSizePercent.map(ReaderCSSSanitizer.fontSizePercent)
        result.lineHeight = lineHeight.map(ReaderCSSSanitizer.lineHeight)
        result.maxWidth = maxWidth.map(ReaderCSSSanitizer.maxWidth)
        result.paddingH = paddingH.map(ReaderCSSSanitizer.paddingH)
        result.paddingV = paddingV.map(ReaderCSSSanitizer.paddingV)
        result.paragraphIndent = paragraphIndent.map(Self.clampEm)
        result.paragraphSpacing = paragraphSpacing.map(Self.clampEm)
        result.light = Self.cleanColors(light)
        result.dark = Self.cleanColors(dark)
        return result
    }

    private static func clampEm(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(3, max(0, value))
    }

    private static func cleanFont(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let cleaned = ReaderCSSSanitizer.fontFamily(raw, fallback: "")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanColors(_ colors: ModeColors) -> ModeColors {
        func clean(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let value = ReaderCSSSanitizer.hexColor(raw, fallback: "")
            return value.isEmpty ? nil : value
        }
        return ModeColors(background: clean(colors.background), ink: clean(colors.ink), link: clean(colors.link))
    }
}
