import Foundation

/// Prepares chapter markup served by `EPUBResourceSchemeHandler` (roadmap M3, contracts C4 and C5).
///
/// Interim and string level: it only inserts a stylesheet link and, when missing, a `lang` attribute.
/// It never edits the body, so offsets (C2) and `EPUBAnchor.currentLayout` are unaffected. M6 replaces
/// the string scanning with SwiftSoup. Pure, so it is tested without WebKit.
enum ServedChapter {
    /// App resource key (see `EPUBResourceSchemeHandler.appResources`) holding the host stylesheet.
    static let readerStylesheetPath = "__app/reader.css"

    /// Absolute path so it resolves under `honeycrisp-epub://book/` from a chapter at any depth.
    static let readerStylesheetLink = "<link rel=\"stylesheet\" type=\"text/css\" href=\"/\(readerStylesheetPath)\"/>"

    /// Returns `data` with the host stylesheet link as the last child of `<head>` (so it is last in the
    /// cascade) and `lang` on the root element when the book has none. Unchanged when the bytes are not
    /// UTF-8, when there is no `<html>` element, or when nothing needs inserting.
    static func prepare(_ data: Data, language: String?) -> Data {
        guard let text = String(data: data, encoding: .utf8),
            let rootTag = rootStartTag(in: text)
        else { return data }

        var insertions: [(index: String.Index, text: String)] = []
        if let language, isSafeLanguage(language), !hasLanguageAttribute(text[rootTag]) {
            let isSelfClosing = text[rootTag].hasSuffix("/>")
            let closing = text.index(rootTag.upperBound, offsetBy: isSelfClosing ? -2 : -1)
            insertions.append((closing, " lang=\"\(language)\""))
        }
        if !text.contains("/\(readerStylesheetPath)\"") {
            if let headEnd = text.range(
                of: "</head>", options: .caseInsensitive, range: rootTag.upperBound..<text.endIndex)
            {
                insertions.append((headEnd.lowerBound, readerStylesheetLink))
            } else if !hasHeadStartTag(in: text, after: rootTag.upperBound) {
                insertions.append((rootTag.upperBound, "<head>\(readerStylesheetLink)</head>"))
            }
        }
        guard !insertions.isEmpty else { return data }

        var result = ""
        var cursor = text.startIndex
        for insertion in insertions.sorted(by: { $0.index < $1.index }) {
            result += text[cursor..<insertion.index]
            result += insertion.text
            cursor = insertion.index
        }
        result += text[cursor...]
        return Data(result.utf8)
    }

    /// Range of the root `<html ...>` start tag, found by `<html` followed by whitespace, `>` or `/`.
    private static func rootStartTag(in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let open = text.range(of: "<html", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let next = open.upperBound
            if next < text.endIndex, text[next].isWhitespace || text[next] == ">" || text[next] == "/",
                let close = text[next...].firstIndex(of: ">")
            {
                return open.lowerBound..<text.index(after: close)
            }
            searchStart = open.upperBound
        }
        return nil
    }

    /// True when a `<head` start tag exists after the root tag but no `</head>` was found (for example
    /// `<head/>`); the link is then not inserted rather than creating a second head.
    private static func hasHeadStartTag(in text: String, after index: String.Index) -> Bool {
        var searchStart = index
        while let open = text.range(of: "<head", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let next = open.upperBound
            if next < text.endIndex, text[next].isWhitespace || text[next] == ">" || text[next] == "/" { return true }
            searchStart = open.upperBound
        }
        return false
    }

    private static func hasLanguageAttribute(_ tag: Substring) -> Bool {
        tag.range(of: #"\s(xml:)?lang\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `language` comes from `EPUBParser.sanitizedLanguageTag` in production; it is checked again here
    /// because it is written into markup.
    private static func isSafeLanguage(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }
}
