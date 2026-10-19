import Foundation

struct SkinValidation {
    let css: String
    let light: SkinColorTokens?
    let dark: SkinColorTokens?
    let usesDefaultColors: Bool
    let lowContrast: Bool
    let fontImports: [String]
}

enum SkinValidator {
    static let maxCSSBytes = 160_000
    static let maxTemplateBytes = 16_384
    static let maxPlistBytes = 16_384

    static func validate(css rawCSS: String, template: String) throws -> SkinValidation {
        guard rawCSS.utf8.count <= maxCSSBytes else { throw SkinImportError.invalidBundle("The skin stylesheet is too large.") }
        guard template.utf8.count <= maxTemplateBytes else { throw SkinImportError.invalidBundle("The skin template is too large.") }
        var css = rawCSS.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
        guard !css.contains("</style"), !css.localizedCaseInsensitiveContains("expression("),
              !css.localizedCaseInsensitiveContains("behavior:"), !css.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" })
        else { throw SkinImportError.invalidBundle("The stylesheet contains unsupported or unsafe CSS.") }
        let imports = leadingImports(css)
        let fontImports = imports.compactMap(fontFamily(from:))
        css = removeLeadingImports(css)
        if css.range(of: #"@import\b"#, options: .regularExpression) != nil {
            throw SkinImportError.invalidBundle("Only leading CSS imports are allowed.")
        }
        guard !containsUnsafeURL(css) else { throw SkinImportError.invalidBundle("The stylesheet contains a remote or unsupported URL.") }
        guard !hasForbiddenCanvasRules(css) else { throw SkinImportError.invalidBundle("The stylesheet changes reader layout or scrolling.") }
        css = css.replacingOccurrences(of: "[[font-size]]", with: "16")
        let roots = rootBlocks(in: css)
        let light = try tokens(in: roots.light)
        let dark = roots.dark.isEmpty ? light : (try tokens(in: roots.dark) ?? light)
        let tokenless = light == nil
        let ratios = [light, dark].compactMap { pair -> Double? in
            guard let pair else { return nil }
            return contrast(pair.ink, pair.background)
        }
        guard ratios.allSatisfy({ $0 >= 1.5 }) else { throw SkinImportError.invalidBundle("The skin's text and background colors have insufficient contrast.") }
        guard !css.contains("[[") else { throw SkinImportError.invalidBundle("The stylesheet contains an unsupported macro.") }
        // AO3-native exports keep their source preface as #preface when the
        // reader's replacement option is disabled. Nectar gallery skins target
        // #ao3Preface, so alias that selector to the native container as well.
        css = css.replacingOccurrences(of: "#ao3Preface", with: ":is(#ao3Preface, #preface)")
        return SkinValidation(css: css, light: light, dark: dark, usesDefaultColors: tokenless,
                              lowContrast: ratios.contains(where: { $0 < 4.5 }), fontImports: fontImports)
    }

    private static func leadingImports(_ css: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)^\s*@import\b"#) else { return [] }
        var text = css
        var imports: [String] = []
        while let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let end = findImportEnd(in: text, start: match.range.location) {
            let ns = text as NSString
            imports.append(ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location)))
            text = ns.replacingCharacters(in: NSRange(location: match.range.location, length: end - match.range.location), with: "")
        }
        return imports
    }

    private static func removeLeadingImports(_ css: String) -> String {
        var text = css
        guard let regex = try? NSRegularExpression(pattern: #"(?is)^\s*@import\b"#) else { return text }
        while let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let end = findImportEnd(in: text, start: match.range.location),
              let range = Range(NSRange(location: match.range.location, length: end - match.range.location), in: text)
        {
            text.removeSubrange(range)
        }
        return text
    }

    private static func findImportEnd(in text: String, start: Int) -> Int? {
        var quote: Character?
        var depth = 0
        for index in text.indices.dropFirst(start) {
            let char = text[index]
            if let current = quote { if char == current { quote = nil }; continue }
            if char == "'" || char == "\"" { quote = char; continue }
            if char == "(" { depth += 1 }
            if char == ")" { depth = max(0, depth - 1) }
            if char == ";" && depth == 0 { return text.distance(from: text.startIndex, to: index) + 1 }
        }
        return nil
    }

    private static func fontFamily(from importRule: String) -> String? {
        guard importRule.contains("fonts.googleapis.com"), let marker = importRule.range(of: "family=") else { return nil }
        let value = importRule[marker.upperBound...].prefix { $0 != "&" && $0 != "'" && $0 != "\"" }
        return value.isEmpty ? nil : String(value).removingPercentEncoding ?? String(value)
    }

    private static func containsUnsafeURL(_ css: String) -> Bool {
        let chars = Array(css)
        var index = 0
        while index < chars.count {
            if chars[index] == "\"" || chars[index] == "'" {
                let quote = chars[index]
                index += 1
                while index < chars.count {
                    if chars[index] == "\\" { index += 2; continue }
                    if chars[index] == quote { index += 1; break }
                    index += 1
                }
                continue
            }
            if index + 4 < chars.count, String(chars[index...index + 3]).lowercased() == "url(" {
                index += 4
                while index < chars.count && chars[index].isWhitespace { index += 1 }
                var quote: Character?
                if index < chars.count && (chars[index] == "\"" || chars[index] == "'") { quote = chars[index]; index += 1 }
                let start = index
                while index < chars.count {
                    if let quote, chars[index] == quote { break }
                    if quote == nil && chars[index] == ")" { break }
                    index += 1
                }
                let value = String(chars[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("%23") || value.hasPrefix("#") || value.lowercased().hasPrefix("data:") {
                    if quote != nil && index < chars.count { index += 1 }
                    while index < chars.count && chars[index] != ")" { index += 1 }
                    if index < chars.count { index += 1 }
                    continue
                }
                return true
            }
            index += 1
        }
        return false
    }

    private static func hasForbiddenCanvasRules(_ css: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)(?:html|body)\s*\{([^}]*)\}"#) else { return true }
        let ns = css as NSString
        let forbidden = #"(?i)(?:^|;)\s*(position|transform|overflow|height|min-height|width|column-[\w-]+)\s*:"#
        return regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).contains { match in
            ns.substring(with: match.range(at: 1)).range(of: forbidden, options: .regularExpression) != nil
        }
    }

    private static func rootBlocks(in css: String) -> (light: String, dark: String) {
        guard let darkRegex = try? NSRegularExpression(pattern: #"(?is)@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)\s*\{"#) else { return (css, "") }
        let ns = css as NSString
        var dark = ""
        var mediaRanges: [NSRange] = []
        for match in darkRegex.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            let openBrace = NSMaxRange(match.range) - 1
            guard let closeBrace = matchingBrace(in: ns, openingAt: openBrace) else { continue }
            let contentStart = NSMaxRange(match.range)
            dark += ns.substring(with: NSRange(location: contentStart, length: closeBrace - contentStart))
            mediaRanges.append(NSRange(location: match.range.location, length: closeBrace - match.range.location + 1))
        }
        var lightCSS = css
        for range in mediaRanges.sorted(by: { $0.location > $1.location }) {
            lightCSS = (lightCSS as NSString).replacingCharacters(in: range, with: "")
        }
        return (lightCSS, dark)
    }

    private static func matchingBrace(in css: NSString, openingAt start: Int) -> Int? {
        var depth = 0
        var quote: unichar = 0
        var escaped = false
        for index in start..<css.length {
            let character = css.character(at: index)
            if escaped { escaped = false; continue }
            if character == 92 { escaped = true; continue }
            if quote != 0 {
                if character == quote { quote = 0 }
                continue
            }
            if character == 34 || character == 39 { quote = character; continue }
            if character == 123 { depth += 1 }
            if character == 125 {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func tokens(in css: String) throws -> SkinColorTokens? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is):root\s*\{([^}]*)\}"#) else { return nil }
        let ns = css as NSString
        let rootMatches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).filter {
            braceDepth(before: $0.range.location, in: css) == 0
        }
        var values: [String: String] = [:]
        for match in rootMatches {
            let block = ns.substring(with: match.range(at: 1))
            for key in ["bg", "ink", "link"] {
                if let value = try declaration("--nnw-\(key)", in: block) {
                    guard isHex(value) else { throw SkinImportError.invalidBundle("Skin token --nnw-\(key) must be a literal hex color.") }
                    values[key] = value
                }
            }
        }
        guard let bg = values["bg"], let ink = values["ink"], let link = values["link"] else {
            if values.isEmpty { return inferredTokens(in: css) }
            throw SkinImportError.invalidBundle("A skin must provide all three --nnw-bg, --nnw-ink and --nnw-link tokens.")
        }
        return SkinColorTokens(background: bg, ink: ink, link: link)
    }

    /// Older dark skins such as AO3 Reversi predate the --nnw-* token contract
    /// and declare their palette directly on `body` and `a`. Infer a palette
    /// only when all three values are simple literal colors; otherwise retain
    /// the documented Honeycrisp defaults for tokenless skins.
    private static func inferredTokens(in css: String) -> SkinColorTokens? {
        guard let bodyRule = firstRule(for: "body", in: css),
              let anchorRule = firstRule(for: "a", in: css),
              let background = try? declaration("background-color", in: bodyRule),
              let ink = try? declaration("color", in: bodyRule),
              let link = try? declaration("color", in: anchorRule),
              isHex(background), isHex(ink), isHex(link)
        else { return nil }
        return SkinColorTokens(background: background, ink: ink, link: link)
    }

    private static func firstRule(for selector: String, in css: String) -> String? {
        let escapedSelector = NSRegularExpression.escapedPattern(for: selector)
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)\\b\(escapedSelector)\\s*\\{([^}]*)\\}"
        ) else { return nil }
        let ns = css as NSString
        return regex.firstMatch(in: css, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private static func braceDepth(before utf16Offset: Int, in css: String) -> Int {
        let ns = css as NSString
        let prefix = ns.substring(to: min(utf16Offset, ns.length))
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in prefix {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character }
            else if character == "{" { depth += 1 }
            else if character == "}" { depth = max(0, depth - 1) }
        }
        return depth
    }

    private static func declaration(_ name: String, in block: String) throws -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?:^|;)\s*\#(name)\s*:\s*(#[0-9a-f]{3}(?:[0-9a-f]{3})?)\s*(?:;|$)"#) else { return nil }
        let ns = block as NSString
        guard let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)) else {
            if block.range(of: #"(?i)(?:^|;)\s*\#(name)\s*:"# , options: .regularExpression) != nil {
                throw SkinImportError.invalidBundle("Skin token \(name) must be a literal hex color.")
            }
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func isHex(_ color: String) -> Bool {
        ReaderCSSSanitizer.hexColor(color, fallback: "") != ""
    }

    private static func luminance(_ color: String) -> Double {
        let normalized = ReaderCSSSanitizer.hexColor(color, fallback: "#000000")
        let chars = Array(normalized.dropFirst())
        let values = stride(from: 0, to: 6, by: 2).map { Int(String(chars[$0...$0 + 1]), radix: 16)! }
        let channels = values.map { value -> Double in
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    static func contrast(_ foreground: String, _ background: String) -> Double {
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

