import Foundation

/// Pure encoder/decoder and slug generator for individual on-disk theme files.
/// Conforms to Decision R19 / Milestone M2.1:
/// - Shape: `{ "version": 1, "theme": { ... } }` (`ThemeExport` schema)
/// - Sorted keys and pretty-printed formatting
/// - Identity is `theme.id`, never the file name or slug
/// - Sanitizes values via `ReaderCSSSanitizer`
/// - Respects `isDefault` and `seedKey` only when matching a known seed theme
enum ThemeFileCodec {
    static let currentVersion = 1
    static let fileExtension = "honeycrisp-theme.json"

    /// Encodes a theme to pretty-printed, key-sorted JSON data.
    static func encode(theme: Theme) throws -> Data {
        let envelope = ThemeExport(version: currentVersion, theme: theme)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Decodes a theme file preserving its original `id`.
    /// `validSeedKeys` ensures that `isDefault` and `seedKey` are only granted
    /// if the file actually matches one of the app's predefined seeds.
    static func decode(data: Data, validSeedKeys: Set<String> = []) throws -> Theme {
        let envelope = try JSONDecoder().decode(ThemeExport.self, from: data)
        guard envelope.version == currentVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rawTheme = envelope.theme
        let rawName = String(rawTheme.name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? "Theme" : rawName

        let isRecognizedSeed = rawTheme.seedKey.map { validSeedKeys.contains($0) } ?? false
        let isDefault = isRecognizedSeed && rawTheme.isDefault
        let seedKey = isRecognizedSeed ? rawTheme.seedKey : nil

        return Theme(
            id: rawTheme.id,
            name: name,
            light: ThemeColorSet(
                background: ReaderCSSSanitizer.hexColor(rawTheme.light.background, fallback: ReaderCSSSanitizer.fallbackBackground),
                text: ReaderCSSSanitizer.hexColor(rawTheme.light.text, fallback: ReaderCSSSanitizer.fallbackText),
                link: ReaderCSSSanitizer.hexColor(rawTheme.light.link, fallback: ReaderCSSSanitizer.fallbackLink)
            ),
            dark: ThemeColorSet(
                background: ReaderCSSSanitizer.hexColor(rawTheme.dark.background, fallback: "#1e1e1e"),
                text: ReaderCSSSanitizer.hexColor(rawTheme.dark.text, fallback: "#eeeeee"),
                link: ReaderCSSSanitizer.hexColor(rawTheme.dark.link, fallback: "#6ba8ff")
            ),
            fontFamily: ReaderCSSSanitizer.fontFamily(rawTheme.fontFamily),
            fontSizePercent: ReaderCSSSanitizer.fontSizePercent(rawTheme.fontSizePercent),
            lineHeight: ReaderCSSSanitizer.lineHeight(rawTheme.lineHeight),
            maxWidth: ReaderCSSSanitizer.maxWidth(rawTheme.maxWidth),
            paddingH: ReaderCSSSanitizer.paddingH(rawTheme.paddingH),
            paddingV: min(120, max(0, rawTheme.paddingV)),
            textAlignment: rawTheme.textAlignment,
            hyphenate: rawTheme.hyphenate,
            paragraphSpacing: ReaderCSSSanitizer.paragraphSpacing(rawTheme.paragraphSpacing),
            paragraphIndent: rawTheme.paragraphIndent.map(ReaderCSSSanitizer.paragraphIndent),
            boldWeight: rawTheme.boldWeight,
            isDefault: isDefault,
            seedKey: seedKey
        )
    }

    /// Generates a filesystem slug from a theme name per M2.1:
    /// - Strips `/`, `:`, `\`
    /// - Strips control characters
    /// - Strips leading dots
    /// - Trims whitespace
    /// - Caps at 80 characters
    /// - Empty becomes "Theme"
    static func slug(for name: String) -> String {
        var cleaned = ""
        let forbidden: Set<Character> = ["/", ":", "\\"]
        for scalar in name.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            let char = Character(scalar)
            if forbidden.contains(char) { continue }
            cleaned.append(char)
        }
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 80 {
            cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? "Theme" : cleaned
    }

    /// Returns a filename for a slug with an optional collision counter (`slug.honeycrisp-theme.json`
    /// or `slug-2.honeycrisp-theme.json`).
    static func filename(for slug: String, collisionIndex: Int = 1) -> String {
        if collisionIndex <= 1 {
            return "\(slug).\(fileExtension)"
        } else {
            return "\(slug)-\(collisionIndex).\(fileExtension)"
        }
    }
}
