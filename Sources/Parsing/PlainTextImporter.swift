// PlainTextImporter.swift
// Converts plain text (.txt) files into structured EPUBPackage instances (FRAMEWORK L0/L1)

import Foundation

struct PlainTextImporter {

    struct RawChapter {
        let title: String
        let bodyHTML: String
    }

    struct Metadata {
        var title: String
        var author: String
    }

    private static let targetChapterCharacterLimit = 25_000

    static func importDocument(at url: URL, to destinationDir: URL) throws -> EPUBPackage {
        let data = try Data(contentsOf: url)
        let decoded = ChapterDecoder.decode(data).text
        let defaultTitle = url.deletingPathExtension().lastPathComponent
        return try createPackage(from: decoded, defaultTitle: defaultTitle, destinationDir: destinationDir)
    }

    static func createPackage(from text: String, defaultTitle: String, destinationDir: URL) throws -> EPUBPackage {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawParagraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let (metadata, remainingParagraphs) = extractMetadata(from: rawParagraphs, defaultTitle: defaultTitle)
        let chapters = splitChapters(from: remainingParagraphs, defaultTitle: metadata.title)

        return try writePackage(
            chapters: chapters,
            metadata: metadata,
            destinationDir: destinationDir
        )
    }

    private static func extractMetadata(
        from paragraphs: [String],
        defaultTitle: String
    ) -> (Metadata, [String]) {
        var title = defaultTitle
        var author = "Unknown Author"
        var consumed = 0

        for paragraph in paragraphs.prefix(5) {
            let lines = paragraph.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var isMetaParagraph = false

            for line in lines {
                let cleanLine = line.hasPrefix(">") ? line.dropFirst().trimmingCharacters(in: .whitespaces) : line
                let lower = cleanLine.lowercased()

                if lower.hasPrefix("title:") {
                    title = String(cleanLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    isMetaParagraph = true
                } else if lower.hasPrefix("author:") || lower.hasPrefix("by:") {
                    let prefixLength = lower.hasPrefix("author:") ? 7 : 3
                    author = String(cleanLine.dropFirst(prefixLength)).trimmingCharacters(in: .whitespaces)
                    isMetaParagraph = true
                }
            }

            if isMetaParagraph {
                consumed += 1
            } else {
                break
            }
        }

        let remaining = Array(paragraphs.dropFirst(consumed))
        return (Metadata(title: title, author: author), remaining.isEmpty ? paragraphs : remaining)
    }

    private static func splitChapters(from paragraphs: [String], defaultTitle: String) -> [RawChapter] {
        var chapters: [RawChapter] = []
        var currentTitle = defaultTitle
        var currentHTML = ""
        var currentLength = 0

        for paragraph in paragraphs {
            if isSceneBreak(paragraph) {
                currentHTML += "<hr class=\"scene-break\"/>\n"
                continue
            }

            var lines = paragraph.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if let firstLine = lines.first, let heading = detectHeadingLine(firstLine) {
                if !currentHTML.isEmpty {
                    chapters.append(RawChapter(title: currentTitle, bodyHTML: currentHTML))
                    currentHTML = ""
                    currentLength = 0
                }
                currentTitle = heading
                lines.removeFirst()
                if lines.isEmpty {
                    continue
                }
            }

            if currentLength >= targetChapterCharacterLimit && !currentHTML.isEmpty {
                chapters.append(RawChapter(title: currentTitle, bodyHTML: currentHTML))
                currentTitle = "\(defaultTitle) (Part \(chapters.count + 1))"
                currentHTML = ""
                currentLength = 0
            }

            let htmlSnippet = formatParagraphLines(lines)
            currentHTML += htmlSnippet + "\n"
            currentLength += paragraph.count
        }

        if !currentHTML.isEmpty || chapters.isEmpty {
            chapters.append(RawChapter(title: currentTitle, bodyHTML: currentHTML))
        }

        return chapters
    }

    private static func detectHeadingLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed.count <= 100 else { return nil }

        let clean = trimmed.hasPrefix(">") ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed

        let patterns = [
            #"^(?:chapter|book|part|section|act|scene)\s+[0-9ivxlcdm]+(?::\s*.*)?$"#,
            #"^[0-9]+\.\s+[A-Za-z0-9].*$"#,
            #"^[ivxlcdm]+\.\s*$"#,
        ]

        for pattern in patterns where clean.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return clean
        }
        return nil
    }

    private static func isSceneBreak(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        let breakPatterns = ["---", "***", "* * *", "___", "- - -"]
        return breakPatterns.contains(trimmed)
    }

    private static func formatParagraphLines(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        var result: [String] = []
        var currentBlock: [String] = []
        var isBlockQuote = false

        for line in lines {
            let lineIsQuote = line.hasPrefix(">")
            if currentBlock.isEmpty {
                isBlockQuote = lineIsQuote
                currentBlock.append(line)
            } else if lineIsQuote == isBlockQuote {
                currentBlock.append(line)
            } else {
                result.append(renderBlock(currentBlock, isQuote: isBlockQuote))
                currentBlock = [line]
                isBlockQuote = lineIsQuote
            }
        }
        if !currentBlock.isEmpty {
            result.append(renderBlock(currentBlock, isQuote: isBlockQuote))
        }
        return result.joined(separator: "\n")
    }

    private static func renderBlock(_ lines: [String], isQuote: Bool) -> String {
        let text = lines.map { line in
            let clean = isQuote && line.hasPrefix(">") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            return clean
        }.joined(separator: " ")
        let escaped = escapeHTML(text)
        return isQuote ? "<blockquote><p>\(escaped)</p></blockquote>" : "<p>\(escaped)</p>"
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
                <title>\(escapeHTML(chapter.title))</title>
            </head>
            <body>
                <h1>\(escapeHTML(chapter.title))</h1>
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
