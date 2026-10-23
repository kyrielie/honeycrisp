import Foundation
import SwiftSoup

/// Harvests simple publisher CSS rules (Rule N3) and semantic HTML5 structures (Rule N6)
/// to apply inline onto chapter markup (Decision R21).
enum ChapterStyles {
    struct HarvestedRule: Equatable {
        let selector: String
        let isHidden: Bool
        let declarations: [String: String]
    }

    /// Strips CSS comments (/* ... */) from the raw stylesheet text.
    static func stripComments(_ css: String) -> String {
        var result = ""
        var index = css.startIndex
        while index < css.endIndex {
            if css[index] == "/", css.index(after: index) < css.endIndex, css[css.index(after: index)] == "*" {
                index = css.index(after: css.index(after: index))
                while index < css.endIndex {
                    if css[index] == "*", css.index(after: index) < css.endIndex, css[css.index(after: index)] == "/" {
                        index = css.index(after: css.index(after: index))
                        break
                    }
                    index = css.index(after: index)
                }
            } else {
                result.append(css[index])
                index = css.index(after: index)
            }
        }
        return result
    }

    /// Strips CSS at-rules (@media, @page, @font-face, @charset, @import).
    static func stripAtRules(_ css: String) -> String {
        var result = ""
        var index = css.startIndex
        while index < css.endIndex {
            if css[index] == "@" {
                var depth = 0
                var foundBrace = false
                while index < css.endIndex {
                    let char = css[index]
                    if char == ";" && depth == 0 && !foundBrace {
                        index = css.index(after: index)
                        break
                    }
                    if char == "{" {
                        depth += 1
                        foundBrace = true
                    } else if char == "}" {
                        depth -= 1
                        if depth <= 0 {
                            index = css.index(after: index)
                            break
                        }
                    }
                    index = css.index(after: index)
                }
            } else {
                result.append(css[index])
                index = css.index(after: index)
            }
        }
        return result
    }

    /// Determines whether a selector string qualifies as a simple selector per Decision R21.
    /// Allowed shapes: tag, .class, #id, tag.class, tag#id.
    static func isSimpleSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty else { return false }
        if selector.contains(" ") || selector.contains(">") || selector.contains("+") ||
            selector.contains("~") || selector.contains(":") || selector.contains("[") ||
            selector.contains("(") || selector.contains("*") {
            return false
        }
        let pattern = #"^[a-zA-Z0-9_-]*(\.[a-zA-Z0-9_-]+|#[a-zA-Z0-9_-]+)?$"#
        guard let range = selector.range(of: pattern, options: .regularExpression) else { return false }
        return range.lowerBound == selector.startIndex && range.upperBound == selector.endIndex
    }

    private static func parseDisplay(_ val: String) -> Bool {
        val == "none"
    }

    private static func parseFontStyle(_ val: String) -> String? {
        (val == "italic" || val == "oblique") ? val : nil
    }

    private static func parseFontWeight(_ val: String) -> String? {
        if val == "bold" || val == "bolder" {
            return "bold"
        }
        if let num = Int(val), num >= 600 {
            return "bold"
        }
        return nil
    }

    private static func parseTextDecoration(_ val: String) -> String? {
        let hasUnderline = val.contains("underline")
        let hasStrike = val.contains("line-through") || val.contains("strike")
        if hasUnderline && hasStrike {
            return "underline line-through"
        }
        if hasUnderline {
            return "underline"
        }
        if hasStrike {
            return "line-through"
        }
        return nil
    }

    private static func parseTextAlign(_ val: String) -> String? {
        (val == "center" || val == "right") ? val : nil
    }

    private static func parseFontFamily(_ val: String) -> String? {
        let isMono = val.contains("monospace") || val.contains("courier") ||
            val.contains("consolas") || val.contains("menlo")
        return isMono ? "monospace" : nil
    }

    /// Parses declarations block and filters against the semantic property whitelist.
    static func parseDeclarations(_ raw: String) -> (isHidden: Bool, declarations: [String: String]) {
        var isHidden = false
        var declarations: [String: String] = [:]
        let items = raw.split(separator: ";")

        for item in items {
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let prop = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = parts[1]
                .replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !prop.isEmpty, !val.isEmpty else { continue }

            if prop == "display", parseDisplay(val) {
                isHidden = true
            } else if prop == "font-style", let res = parseFontStyle(val) {
                declarations[prop] = res
            } else if prop == "font-weight", let res = parseFontWeight(val) {
                declarations[prop] = res
            } else if prop == "text-decoration" || prop == "text-decoration-line", let res = parseTextDecoration(val) {
                declarations["text-decoration"] = res
            } else if prop == "text-align", let res = parseTextAlign(val) {
                declarations[prop] = res
            } else if prop == "font-family", let res = parseFontFamily(val) {
                declarations[prop] = res
            }
        }
        return (isHidden, declarations)
    }

    /// Parses all rules from raw stylesheet text, maintaining cascade source order.
    static func parseRules(from css: String) -> [HarvestedRule] {
        let clean = stripAtRules(stripComments(css))
        var rules: [HarvestedRule] = []
        let parts = clean.split(separator: "}")

        for part in parts {
            let ruleParts = part.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: true)
            guard ruleParts.count == 2 else { continue }
            let rawSelector = String(ruleParts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawDeclarations = String(ruleParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawSelector.isEmpty, !rawDeclarations.isEmpty else { continue }

            let (isHidden, declarations) = parseDeclarations(rawDeclarations)
            guard isHidden || !declarations.isEmpty else { continue }

            let subSelectors = rawSelector.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for sub in subSelectors {
                guard isSimpleSelector(sub) else { continue }
                rules.append(HarvestedRule(selector: sub, isHidden: isHidden, declarations: declarations))
            }
        }
        return rules
    }

    /// Resolves stylesheet href relative to chapter or book root.
    static func resolveStylesheetURL(href: String, chapterURL: URL?, rootFolder: URL?) -> URL? {
        let clean = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("://") else { return nil }

        let resolved: URL
        if clean.hasPrefix("/") {
            guard let root = rootFolder else { return nil }
            let path = String(clean.dropFirst())
            resolved = URL(fileURLWithPath: path, relativeTo: root).absoluteURL.resolvingSymlinksInPath()
        } else {
            guard let chapter = chapterURL else { return nil }
            let base = chapter.deletingLastPathComponent()
            resolved = URL(fileURLWithPath: clean, relativeTo: base).absoluteURL.resolvingSymlinksInPath()
        }

        if let root = rootFolder {
            let stdRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let stdResolved = resolved.standardizedFileURL.path
            guard stdResolved.hasPrefix(stdRoot) else { return nil }
        }
        return resolved
    }

    /// Collects harvested rules from in-document styles and external stylesheets in cascade source order.
    static func harvestRules(
        from document: Document,
        chapterURL: URL?,
        rootFolder: URL?
    ) -> [HarvestedRule] {
        var rules: [HarvestedRule] = []
        guard let nodes = try? document.select("link[rel*='stylesheet'], link[rel*='StyleSheet'], style") else {
            return rules
        }

        for node in nodes {
            let tag = node.tagName().lowercased()
            if tag == "style" {
                let css = node.data().isEmpty ? ((try? node.html()) ?? "") : node.data()
                rules.append(contentsOf: parseRules(from: css))
            } else if tag == "link" {
                guard let href = try? node.attr("href"),
                      let fileURL = resolveStylesheetURL(href: href, chapterURL: chapterURL, rootFolder: rootFolder),
                      let data = try? Data(contentsOf: fileURL),
                      let css = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    continue
                }
                rules.append(contentsOf: parseRules(from: css))
            }
        }
        return rules
    }

    /// Merges harvested declarations into an element's existing inline style without overriding existing inline properties.
    static func mergeInlineStyles(_ harvested: [String: String], into element: Element) throws {
        guard !harvested.isEmpty else { return }
        var existingPairs: [(String, String)] = []
        var existingKeys = Set<String>()

        if element.hasAttr("style") {
            let raw = try element.attr("style")
            let declarations = raw.split(separator: ";")
            for decl in declarations {
                let parts = decl.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let prop = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                guard !prop.isEmpty, !val.isEmpty else { continue }
                existingPairs.append((prop, val))
                existingKeys.insert(prop)
            }
        }

        var merged = existingPairs
        for (prop, val) in harvested.sorted(by: { $0.key < $1.key }) where !existingKeys.contains(prop) {
            merged.append((prop, val))
        }

        let styleString = merged.map { "\($0.0): \($0.1);" }.joined(separator: " ")
        try element.attr("style", styleString)
    }

    /// Applies harvested rules onto elements within the chapter body.
    static func applyHarvestedRules(_ rules: [HarvestedRule], to body: Element) throws {
        var elementDeclarations: [Element: [String: String]] = [:]

        for rule in rules {
            guard let matchingElements = try? body.select(rule.selector) else { continue }
            for element in matchingElements {
                if rule.isHidden {
                    try element.attr("hidden", "")
                }
                if !rule.declarations.isEmpty {
                    var current = elementDeclarations[element] ?? [:]
                    for (prop, val) in rule.declarations {
                        current[prop] = val
                    }
                    elementDeclarations[element] = current
                }
            }
        }

        for (element, declarations) in elementDeclarations {
            try mergeInlineStyles(declarations, into: element)
        }
    }

    /// Applies semantic HTML5 rules (Rule N6): open details blocks and hide standalone nav blocks.
    static func applySemanticHTML5Rules(to body: Element) throws {
        for details in try body.select("details") where !details.hasAttr("open") {
            try details.attr("open", "")
        }
        for nav in try body.select("nav") where !nav.hasAttr("hidden") {
            try nav.attr("hidden", "")
        }
    }

    /// Removes style elements from the given root to ensure unharvested publisher CSS does not leak.
    static func removeStyleElements(in root: Element) throws {
        for style in try root.select("style") {
            try style.remove()
        }
    }

    /// Harvests publisher stylesheet rules, inlines whitelisted typography, hides display:none elements,
    /// applies HTML5 details/nav semantics, and strips raw style tags.
    static func apply(
        to document: Document,
        body: Element,
        chapterURL: URL?,
        rootFolder: URL?
    ) throws {
        let rules = harvestRules(from: document, chapterURL: chapterURL, rootFolder: rootFolder)
        if !rules.isEmpty {
            try applyHarvestedRules(rules, to: body)
        }
        try applySemanticHTML5Rules(to: body)
        try removeStyleElements(in: body)
    }
}
