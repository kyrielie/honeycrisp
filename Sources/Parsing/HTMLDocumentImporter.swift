// HTMLDocumentImporter.swift
// Converts single-file HTML documents into structured EPUBPackage instances (FRAMEWORK L0/L1)

import Foundation
import SwiftSoup

struct HTMLDocumentImporter {

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

    static func createPackage(from html: String, defaultTitle: String, destinationDir: URL) throws -> EPUBPackage {
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let metadata = extractMetadata(from: doc, defaultTitle: defaultTitle)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)

        let chapters = try splitChapters(from: body, defaultTitle: metadata.title)

        return try writePackage(
            chapters: chapters,
            metadata: metadata,
            destinationDir: destinationDir
        )
    }

    private static func extractMetadata(from doc: Document, defaultTitle: String) -> Metadata {
        var title = (try? doc.title())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            title = (try? doc.select("meta[property=og:title], meta[name=title]").attr("content"))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if title.isEmpty {
            title = defaultTitle
        }

        var author = (try? doc.select("meta[name=author], meta[property=article:author]").attr("content"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if author.isEmpty {
            author = "Unknown Author"
        }

        return Metadata(title: title, author: author)
    }

    private static func splitChapters(from body: Element, defaultTitle: String) throws -> [RawChapter] {
        if let containerChapters = try splitByContainers(body: body, defaultTitle: defaultTitle), containerChapters.count >= 2 {
            return containerChapters
        }

        if let headingChapters = try splitByHeadings(body: body, defaultTitle: defaultTitle), headingChapters.count >= 2 {
            return headingChapters
        }

        return try splitBySizeCap(body: body, defaultTitle: defaultTitle)
    }

    private static func splitByContainers(body: Element, defaultTitle: String) throws -> [RawChapter]? {
        let articles = try body.select("article").array()
        if articles.count >= 2 {
            return try articles.enumerated().map { index, article in
                let title = try article.select("h1, h2, h3").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(defaultTitle) - Chapter \(index + 1)"
                return RawChapter(title: title, bodyHTML: try article.html())
            }
        }

        let sectionChapters = try body.select(".chapter, .story-chapter, section.chapter").array()
        if sectionChapters.count >= 2 {
            return try sectionChapters.enumerated().map { index, element in
                let title = try element.select("h1, h2, h3").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(defaultTitle) - Chapter \(index + 1)"
                return RawChapter(title: title, bodyHTML: try element.html())
            }
        }

        return nil
    }

    private static func splitByHeadings(body: Element, defaultTitle: String) throws -> [RawChapter]? {
        let h1Count = try body.select("h1").count
        let headingSelector = h1Count >= 2 ? "h1" : "h2"
        let headingCount = headingSelector == "h1" ? h1Count : try body.select("h2").count
        guard headingCount >= 2 else { return nil }

        var chapters: [RawChapter] = []
        var currentTitle = defaultTitle
        var currentHTML = ""

        for child in body.children().array() {
            if child.tagName().lowercased() == headingSelector {
                let trimmedHtml = currentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedHtml.isEmpty {
                    chapters.append(RawChapter(title: currentTitle, bodyHTML: trimmedHtml))
                    currentHTML = ""
                }
                currentTitle = try child.text().trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                currentHTML += try child.outerHtml() + "\n"
            }
        }

        let trimmedHtml = currentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHtml.isEmpty || chapters.isEmpty {
            chapters.append(RawChapter(title: currentTitle, bodyHTML: trimmedHtml))
        }

        return chapters
    }

    private static func splitBySizeCap(body: Element, defaultTitle: String) throws -> [RawChapter] {
        var chapters: [RawChapter] = []
        var currentHTML = ""
        var currentLength = 0

        for child in body.children().array() {
            let childHTML = try child.outerHtml()
            if currentLength >= targetChapterCharacterLimit && !currentHTML.isEmpty {
                chapters.append(RawChapter(title: "\(defaultTitle) (Part \(chapters.count + 1))", bodyHTML: currentHTML))
                currentHTML = ""
                currentLength = 0
            }
            currentHTML += childHTML + "\n"
            currentLength += childHTML.count
        }

        if !currentHTML.isEmpty || chapters.isEmpty {
            let partTitle = chapters.isEmpty ? defaultTitle : "\(defaultTitle) (Part \(chapters.count + 1))"
            chapters.append(RawChapter(title: partTitle, bodyHTML: currentHTML))
        }

        return chapters
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
