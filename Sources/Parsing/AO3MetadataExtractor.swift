// AO3MetadataExtractor.swift
// Extracts structured AO3 metadata from the preface chapter of an EPUB (FRAMEWORK L1 Publication).
// Adapted from Ambrosia/Database/AO3MetadataExtractor.swift. Reads spine[0] first and falls back
// through spine[1..4]; returns nil for books without an AO3 preface.

import Foundation
import SwiftSoup

enum AO3MetadataExtractor {

    /// Number of spine items, counted from the start, searched for the preface.
    static let maxSpineItemsScanned = 5

    /// Reads at most the first `maxSpineItemsScanned` spine items. The record comes from the first one
    /// that holds a `dl.tags` preface; the summary from the first one with a "Summary" heading followed
    /// by a blockquote (the title page, which may come before or after the preface). Returns nil when
    /// no preface is found. Items that cannot be read are skipped.
    static func extract(from package: EPUBPackage) -> AO3MetadataRecord? {
        var record: AO3MetadataRecord?
        var summary: String?
        for url in package.spineURLs.prefix(maxSpineItemsScanned) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let html = ChapterDecoder.decode(data).text
            if record == nil, mightContainPreface(html) { record = extract(from: html) }
            if summary == nil, mightContainSummary(html) { summary = extractSummary(from: html) }
            if record != nil, summary != nil { break }
        }
        guard var found = record else { return nil }
        found.summary = summary
        return found
    }

    /// Cheap string test that lets non-AO3 chapters skip the SwiftSoup parse. It only rules chapters
    /// out; `extract(from:)` decides.
    static func mightContainPreface(_ html: String) -> Bool {
        html.contains("<dl") && html.contains("tags")
    }

    /// Cheap string test, like `mightContainPreface`, for the summary scan.
    static func mightContainSummary(_ html: String) -> Bool {
        html.contains("blockquote") && html.range(of: "summary", options: .caseInsensitive) != nil
    }

    /// The text of the blockquote that directly follows a "Summary" heading (`p`, `h2`, `h3` or `h4`),
    /// with paragraphs joined by a blank line. Nil when there is none.
    static func extractSummary(from html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html),
              let headings = try? doc.select("p, h2, h3, h4").array() else { return nil }
        for heading in headings {
            guard text(of: heading)?.caseInsensitiveCompare("Summary") == .orderedSame,
                  let next = try? heading.nextElementSibling(),
                  next.tagName().lowercased() == "blockquote" else { continue }
            return paragraphText(of: next)
        }
        return nil
    }

    /// Parses one chapter's HTML. Returns nil when it has no `dl.tags` element.
    static func extract(from html: String) -> AO3MetadataRecord? {
        guard let doc = try? SwiftSoup.parse(html),
              let tagsList = try? doc.select("dl.tags").first() else { return nil }

        var record = AO3MetadataRecord()
        if let work = workLink(in: doc) {
            record.storyURL = work.url
            record.workID = work.id
        }

        var completedDate: String?
        var currentField = ""
        for element in tagsList.children().array() {
            let tag = element.tagName().lowercased()
            if tag == "dt" {
                currentField = normalizedField((try? element.text()) ?? "")
            } else if tag == "dd" {
                parseField(currentField, element: element, into: &record, completedDate: &completedDate)
            }
        }

        // One-shots may carry no chapter count at all.
        if record.chapterCurrent == nil && record.chapterTotal == nil {
            record.chapterCurrent = 1
            record.chapterTotal = 1
        }

        record.isComplete = (
            record.chapterCurrent != nil &&
            record.chapterTotal != nil &&
            record.chapterCurrent == record.chapterTotal
        ) || completedDate != nil

        return record
    }

    // MARK: - Field parsing

    private static func parseField(
        _ field: String,
        element: Element,
        into record: inout AO3MetadataRecord,
        completedDate: inout String?
    ) {
        switch field {
        case "rating", "ratings":
            record.rating = text(of: element)
        case "archive warning", "archive warnings", "warning", "warnings":
            record.warnings = linkTexts(in: element)
        case "category", "categories":
            record.categories = linkTexts(in: element)
        case "fandom", "fandoms":
            record.fandoms = linkTexts(in: element)
        case "relationship", "relationships":
            record.relationships = linkTexts(in: element)
        case "character", "characters":
            record.characters = linkTexts(in: element)
        case "additional tag", "additional tags":
            record.additionalTags = linkTexts(in: element)
        case "collection", "collections":
            record.collections = linkTexts(in: element)
        case "language":
            record.language = text(of: element)
        case "series":
            record.series = parseSeries(in: element)
        case "words":
            record.wordCount = parseInt((try? element.text()) ?? "")
        case "chapters":
            let chapters = parseChapters((try? element.text()) ?? "")
            record.chapterCurrent = chapters.current
            record.chapterTotal = chapters.total
        case "stats":
            parseStats((try? element.text()) ?? "", into: &record, completedDate: &completedDate)
        default:
            break
        }
    }

    /// Stats are plain text: whitespace separated `Key: value` pairs such as `Published: 2020-01-01`.
    private static func parseStats(
        _ text: String,
        into record: inout AO3MetadataRecord,
        completedDate: inout String?
    ) {
        let tokens = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var index = 0
        while index < tokens.count - 1 {
            let key = tokens[index].trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
            let value = tokens[index + 1]
            switch key {
            case "published":
                record.publishedDate = value
            case "completed":
                completedDate = value
                record.updatedDate = value
            case "updated":
                record.updatedDate = value
            case "words":
                record.wordCount = parseInt(value)
            case "chapters":
                let chapters = parseChapters(value)
                record.chapterCurrent = chapters.current
                record.chapterTotal = chapters.total
            case "kudos":
                record.kudosCount = parseInt(value)
            default:
                break
            }
            index += 2
        }
    }

    /// The series `dd` interleaves text nodes ("Part 2 of") and links; there are no list elements.
    private static func parseSeries(in element: Element) -> [AO3MetadataRecord.SeriesEntry] {
        var pendingIndex: Int?
        var series: [AO3MetadataRecord.SeriesEntry] = []
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                pendingIndex = firstMatch(
                    in: textNode.text(),
                    pattern: #"(?:,\s*)?[Pp]art\s+([0-9]+)\s+of"#
                ).flatMap(Int.init)
            } else if let link = node as? Element, link.tagName().lowercased() == "a" {
                let href = (try? link.attr("href")) ?? ""
                if let name = text(of: link), let index = pendingIndex {
                    series.append(AO3MetadataRecord.SeriesEntry(
                        name: name,
                        index: index,
                        ao3ID: firstMatch(in: href, pattern: #"/series/([0-9]+)"#)
                    ))
                }
                pendingIndex = nil
            }
        }
        return series
    }

    // MARK: - Helpers

    /// The first `/works/NNN` link, preferring the one in the preface message paragraph.
    private static func workLink(in doc: Document) -> (url: String, id: String)? {
        for selector in ["p.message a[href]", "a[href]"] {
            guard let links = try? doc.select(selector).array() else { continue }
            for link in links {
                guard let href = try? link.attr("href"),
                      let id = firstMatch(in: href, pattern: #"/works/([0-9]+)"#) else { continue }
                return (secureAO3URL(href), id)
            }
        }
        return nil
    }

    private static func secureAO3URL(_ href: String) -> String {
        if href.hasPrefix("https://") { return href }
        if href.hasPrefix("http://") { return "https://" + String(href.dropFirst("http://".count)) }
        return "https://archiveofourown.org" + (href.hasPrefix("/") ? href : "/" + href)
    }

    private static func text(of element: Element) -> String? {
        guard let raw = try? element.text() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func paragraphText(of element: Element) -> String? {
        let paragraphs = ((try? element.select("p").array()) ?? []).compactMap { text(of: $0) }
        if !paragraphs.isEmpty { return paragraphs.joined(separator: "\n\n") }
        return text(of: element)
    }

    private static func linkTexts(in element: Element) -> [String] {
        guard let links = try? element.select("a").array() else { return [] }
        return links.compactMap { text(of: $0) }
    }

    private static func parseInt(_ value: String) -> Int? {
        Int(value.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseChapters(_ value: String) -> (current: Int?, total: Int?) {
        let parts = value.split(separator: "/", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let current = Int(parts.first ?? "")
        let total = parts.count > 1 && parts[1] != "?" ? Int(parts[1]) : nil
        return (current, total)
    }

    private static func normalizedField(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    private static func firstMatch(in string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }
}
