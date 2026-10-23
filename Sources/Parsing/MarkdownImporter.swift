// MarkdownImporter.swift
// Converts Markdown (.md) documents into structured EPUBPackage instances (FRAMEWORK L0/L1)

import Foundation

struct MarkdownImporter {

    struct RawChapter {
        let title: String
        let bodyHTML: String
    }

    struct Metadata {
        var title: String
        var author: String
    }

    enum Block {
        case heading(level: Int, text: String)
        case codeBlock(code: String, language: String?)
        case blockquote(text: String)
        case list(items: [String], isOrdered: Bool)
        case horizontalRule
        case paragraph(text: String)
    }

    private static let targetChapterCharacterLimit = 25_000

    static func importDocument(at url: URL, to destinationDir: URL) throws -> EPUBPackage {
        let data = try Data(contentsOf: url)
        let decoded = ChapterDecoder.decode(data).text
        let defaultTitle = url.deletingPathExtension().lastPathComponent
        return try createPackage(from: decoded, defaultTitle: defaultTitle, destinationDir: destinationDir)
    }

    static func createPackage(from markdown: String, defaultTitle: String, destinationDir: URL) throws -> EPUBPackage {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let (metadata, content) = extractMetadata(from: normalized, defaultTitle: defaultTitle)
        let blocks = parseBlocks(from: content)
        let chapters = splitChapters(from: blocks, defaultTitle: metadata.title)

        return try writePackage(
            chapters: chapters,
            metadata: metadata,
            destinationDir: destinationDir
        )
    }

    private static func extractMetadata(from text: String, defaultTitle: String) -> (Metadata, String) {
        var title = defaultTitle
        var author = "Unknown Author"
        var remaining = text

        // Check for YAML frontmatter
        if text.hasPrefix("---\n") {
            let parts = text.components(separatedBy: "\n---\n")
            if parts.count >= 2 {
                let frontmatter = parts[0].dropFirst(4)
                for line in frontmatter.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let lower = trimmed.lowercased()
                    if lower.hasPrefix("title:") {
                        title = String(trimmed.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    } else if lower.hasPrefix("author:") {
                        author = String(trimmed.dropFirst(7)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    }
                }
                remaining = parts.dropFirst().joined(separator: "\n---\n")
            }
        }

        if title == defaultTitle {
            for line in remaining.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("# ") {
                    title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }

        return (Metadata(title: title, author: author), remaining)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parseBlocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        let rawLines = text.components(separatedBy: "\n")
        var index = 0

        while index < rawLines.count {
            let line = rawLines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < rawLines.count && !rawLines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(rawLines[index])
                    index += 1
                }
                if index < rawLines.count { index += 1 }
                blocks.append(.codeBlock(code: codeLines.joined(separator: "\n"), language: lang.isEmpty ? nil : lang))
                continue
            }

            // Heading
            if let heading = parseHeading(line: trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < rawLines.count && rawLines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let clean = String(rawLines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
                    quoteLines.append(clean)
                    index += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: " ")))
                continue
            }

            // List item
            if isListStart(trimmed) {
                let isOrdered = trimmed.first?.isNumber == true
                var listItems: [String] = []
                while index < rawLines.count && isListStart(rawLines[index].trimmingCharacters(in: .whitespaces)) {
                    let itemText = stripListPrefix(rawLines[index].trimmingCharacters(in: .whitespaces))
                    listItems.append(itemText)
                    index += 1
                }
                blocks.append(.list(items: listItems, isOrdered: isOrdered))
                continue
            }

            // Paragraph
            var paraLines: [String] = []
            while index < rawLines.count {
                let current = rawLines[index]
                let curTrimmed = current.trimmingCharacters(in: .whitespaces)
                if curTrimmed.isEmpty || curTrimmed.hasPrefix("```") || parseHeading(line: curTrimmed) != nil ||
                    isHorizontalRule(curTrimmed) || curTrimmed.hasPrefix(">") || isListStart(curTrimmed) {
                    break
                }
                paraLines.append(curTrimmed)
                index += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(text: paraLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    private static func parseHeading(line: String) -> Block? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let rules = ["---", "***", "___", "- - -", "* * *"]
        return rules.contains(line)
    }

    private static func isListStart(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }
        if let dotIndex = line.firstIndex(of: "."), dotIndex != line.startIndex {
            let prefix = line[..<dotIndex]
            if Int(prefix) != nil, line[dotIndex...].hasPrefix(". ") {
                return true
            }
        }
        return false
    }

    private static func stripListPrefix(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return String(line.dropFirst(2))
        }
        if let dotIndex = line.firstIndex(of: ".") {
            return String(line[dotIndex...].dropFirst(2))
        }
        return line
    }

    private static func splitChapters(from blocks: [Block], defaultTitle: String) -> [RawChapter] {
        let h1Count = blocks.filter {
            if case .heading(let level, _) = $0, level == 1 { return true }
            return false
        }.count
        let splitLevel = h1Count >= 2 ? 1 : 2

        var chapters: [RawChapter] = []
        var currentTitle = defaultTitle
        var currentHTML = ""
        var currentLength = 0

        for block in blocks {
            if case .heading(let level, let text) = block, level <= splitLevel {
                if !currentHTML.isEmpty {
                    chapters.append(RawChapter(title: currentTitle, bodyHTML: currentHTML))
                    currentHTML = ""
                    currentLength = 0
                }
                currentTitle = text
                continue
            }

            let htmlSnippet = renderBlockHTML(block)
            if currentLength >= targetChapterCharacterLimit && !currentHTML.isEmpty {
                chapters.append(RawChapter(title: currentTitle, bodyHTML: currentHTML))
                currentTitle = "\(defaultTitle) (Part \(chapters.count + 1))"
                currentHTML = ""
                currentLength = 0
            }

            currentHTML += htmlSnippet + "\n"
            currentLength += htmlSnippet.count
        }

        if !currentHTML.isEmpty || chapters.isEmpty {
            chapters.append(RawChapter(title: currentTitle, bodyHTML: currentHTML))
        }

        return chapters
    }

    private static func renderBlockHTML(_ block: Block) -> String {
        switch block {
        case .heading(let level, let text):
            return "<h\(level)>\(renderInline(text))</h\(level)>"
        case .codeBlock(let code, let language):
            let langClass = language.map { " class=\"language-\(escapeHTML($0))\"" } ?? ""
            return "<pre><code\(langClass)>\(escapeHTML(code))</code></pre>"
        case .blockquote(let text):
            return "<blockquote><p>\(renderInline(text))</p></blockquote>"
        case .list(let items, let isOrdered):
            let tag = isOrdered ? "ol" : "ul"
            let itemsHTML = items.map { "<li>\(renderInline($0))</li>" }.joined(separator: "\n")
            return "<\(tag)>\n\(itemsHTML)\n</\(tag)>"
        case .horizontalRule:
            return "<hr class=\"scene-break\"/>"
        case .paragraph(let text):
            return "<p>\(renderInline(text))</p>"
        }
    }

    private static func renderInline(_ text: String) -> String {
        var result = escapeHTML(text)

        // Code: `code`
        result = replaceRegex(in: result, pattern: #"`([^`]+)`"#, template: "<code>$1</code>")

        // Images: ![alt](url)
        result = replaceRegex(in: result, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#, template: "<img src=\"$2\" alt=\"$1\"/>")

        // Links: [text](url)
        result = replaceRegex(in: result, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, template: "<a href=\"$2\">$1</a>")

        // Bold + Italic: ***text***
        result = replaceRegex(in: result, pattern: #"\*\*\*([^*]+)\*\*\*"#, template: "<strong><em>$1</em></strong>")

        // Bold: **text**
        result = replaceRegex(in: result, pattern: #"\*\*([^*]+)\*\*"#, template: "<strong>$1</strong>")

        // Italic: *text*
        result = replaceRegex(in: result, pattern: #"\*([^*]+)\*"#, template: "<em>$1</em>")

        return result
    }

    private static func replaceRegex(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func writePackage(
        chapters: [RawChapter],
        metadata: Metadata,
        destinationDir: URL
    ) throws -> EPUBPackage {
        let fm = FileManager.default
        let oebps = destinationDir.appendingPathComponent("OEBPS", isDirectory: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)

        var spineURLs: [URL] = []
        var manifest: [String: EPUBManifestItem] = [:]
        var spine: [EPUBSpineItem] = []

        for (index, chapter) in chapters.enumerated() {
            let filename = "chapter_\(index).xhtml"
            let chapterURL = oebps.appendingPathComponent(filename)
            let xhtml = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>\(chapter.title)</title>
            </head>
            <body>
                <h1>\(chapter.title)</h1>
                \(chapter.bodyHTML)
            </body>
            </html>
            """
            try xhtml.write(to: chapterURL, atomically: true, encoding: .utf8)
            spineURLs.append(chapterURL)

            let manifestID = "chapter-\(index)"
            manifest[manifestID] = EPUBManifestItem(
                id: manifestID,
                href: filename,
                mediaType: "application/xhtml+xml",
                properties: [],
                url: chapterURL
            )
            spine.append(EPUBSpineItem(manifestID: manifestID, url: chapterURL, isLinear: true))
        }

        return EPUBPackage(
            rootFolder: oebps,
            spineURLs: spineURLs,
            title: metadata.title,
            author: metadata.author,
            coverURL: nil,
            manifest: manifest,
            spine: spine,
            version: "3.0"
        )
    }
}
