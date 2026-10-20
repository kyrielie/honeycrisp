import Foundation

/// Pure validation for values that `EPUBParser.readerVarsCSS` interpolates into the reader stylesheet.
///
/// The raw values come from persisted `Theme` JSON and the free-form font field, so they are not
/// guaranteed to be valid CSS. Every function returns either a fully valid value or the fallback;
/// a partially cleaned value is never emitted. No AppKit, so it can be unit-tested directly.
enum ReaderCSSSanitizer {
    static let fallbackBackground = "#ffffff"
    static let fallbackText = "#000000"
    static let fallbackLink = "#0068da"

    static let maxFontFamilyLength = 256
    static let maxFontNameLength = 64

    // MARK: Colors

    /// Normalizes `#rgb`, `#rrggbb` (leading `#` optional, surrounding whitespace ignored) to lowercase
    /// `#rrggbb`. Anything else, including alpha forms and functional notations, returns `fallback`.
    static func hexColor(_ raw: String, fallback: String) -> String {
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 3 || digits.count == 6, digits.unicodeScalars.allSatisfy(isASCIIHexDigit) else {
            return fallback
        }
        let lower = digits.lowercased()
        if lower.count == 3 {
            return "#" + lower.map { "\($0)\($0)" }.joined()
        }
        return "#" + lower
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }

    // MARK: Font family

    /// Accepts a comma-separated font stack whose items are either bare names or single or double quoted
    /// names. A name may contain letters, digits, spaces, `.`, `_` and `-`, is at most `maxFontNameLength`
    /// characters, and a bare name must not start with a digit. The whole stack is at most
    /// `maxFontFamilyLength` characters. Braces, semicolons, angle brackets, parentheses (so `url(`),
    /// backslashes and unbalanced quotes all fail. A valid value is returned trimmed but otherwise
    /// unchanged, so the preset stacks round trip exactly. Invalid input returns `fallback`.
    static func fontFamily(_ raw: String, fallback: String = FontPresets.defaultStack) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maxFontFamilyLength else { return fallback }
        if FontPresets.all.contains(where: { $0.cssStack == value }) { return value }
        guard let items = splitStack(value), !items.isEmpty, items.allSatisfy(isValidFontItem) else { return fallback }
        return value
    }

    /// Splits on commas outside quotes. Returns nil for an unterminated quote or a backslash.
    private static func splitStack(_ value: String) -> [String]? {
        var items: [String] = []
        var current = ""
        var openQuote: Character?
        for char in value {
            if char == "\\" { return nil }
            if let quote = openQuote {
                if char == quote { openQuote = nil }
                current.append(char)
            } else if char == "'" || char == "\"" {
                openQuote = char
                current.append(char)
            } else if char == "," {
                items.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        guard openQuote == nil else { return nil }
        items.append(current)
        return items
    }

    private static func isValidFontItem(_ rawItem: String) -> Bool {
        let item = rawItem.trimmingCharacters(in: .whitespaces)
        guard let first = item.first else { return false }
        if first == "'" || first == "\"" {
            guard item.count >= 3, item.last == first else { return false }
            let inner = String(item.dropFirst().dropLast())
            return isValidFontName(inner)
        }
        guard !first.isNumber else { return false }
        return isValidFontName(item)
    }

    private static func isValidFontName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxFontNameLength else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }
    }

    // MARK: Numbers

    /// Same ranges the `SettingsManager` setters enforce. The getters read persisted JSON unclamped,
    /// so these guard the stylesheet against hand-edited or corrupt stored values.
    static func fontSizePercent(_ value: Int) -> Int { min(300, max(50, value)) }

    static func maxWidth(_ value: Int) -> Int { min(1400, max(320, value)) }

    static func paddingH(_ value: Int) -> Int { min(120, max(0, value)) }

    /// Non-finite input returns the default line height (1.6).
    static func lineHeight(_ value: Double) -> Double {
        guard value.isFinite else { return 1.6 }
        return min(2.4, max(1.2, value))
    }

    static func paragraphSpacing(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(3, max(0, value))
    }
}
