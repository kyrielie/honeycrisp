// TOCParser.swift
// Parses EPUB Table of Contents from toc.ncx or nav.xhtml

import Foundation
import SwiftSoup

struct TOCEntry: Identifiable {
    let id: UUID
    let title: String
    let href: String
    let absoluteURL: URL
    let playOrder: Int
    let depth: Int
    var children: [TOCEntry]

    init(title: String, href: String, absoluteURL: URL, playOrder: Int, depth: Int = 0, children: [TOCEntry] = []) {
        self.id = UUID()
        self.title = title
        self.href = href
        self.absoluteURL = absoluteURL
        self.playOrder = playOrder
        self.depth = depth
        self.children = children
    }
}

struct TOCNode: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let children: [TOCNode]
    let spineIndex: Int?
    let isLandmark: Bool
}

final class TOCParser {

    /// Attempts NCX first, falls back to nav.xhtml
    func parseTOC(for pkg: EPUBPackage) -> [TOCEntry] {
        let root = pkg.rootFolder

        if let navURL = pkg.navigationURL,
           let entries = parseNav(at: navURL, rootFolder: root), !entries.isEmpty {
            return entries
        }
        if let ncxURL = findNCX(in: root),
           let entries = parseNCX(at: ncxURL, rootFolder: root), !entries.isEmpty {
            return entries
        }
        if let navURL = findNav(in: root),
           let entries = parseNav(at: navURL, rootFolder: root), !entries.isEmpty {
            return entries
        }
        return synthesiseFromSpine(pkg)
    }

    func startReadingNode(in package: EPUBPackage, toc: [TOCEntry]) -> TOCNode? {
        if let landmark = package.landmarks.first(where: { ["bodymatter", "text"].contains($0.type.lowercased()) }),
           let index = package.spineURLs.firstIndex(where: {
               $0.standardizedFileURL.path == landmark.url.standardizedFileURL.path
           }) {
            let title = landmark.title.isEmpty ? "Start Reading" : landmark.title
            return TOCNode(title: title, url: landmark.url, children: [], spineIndex: index, isLandmark: true)
        }

        if let firstLinearIndex = package.spine.firstIndex(where: \.isLinear),
           let nextLinearIndex = package.spine.indices.first(where: { $0 > firstLinearIndex && package.spine[$0].isLinear }) {
            let first = package.spine[firstLinearIndex]
            let firstName = first.url.deletingPathExtension().lastPathComponent.lowercased()
                .replacingOccurrences(of: "[_-]", with: " ", options: .regularExpression)
            let firstTitle = heading(in: first.url)?.lowercased() ?? ""
            let frontMatterTerms = ["cover", "title page", "contents", "table of contents"]
            if frontMatterTerms.contains(where: { firstName.contains($0) || firstTitle.contains($0) }) {
                let next = package.spine[nextLinearIndex]
                return TOCNode(title: "Start Reading", url: next.url, children: [], spineIndex: nextLinearIndex, isLandmark: false)
            }
        }

        guard let first = package.spine.first(where: \.isLinear) ?? package.spine.first else { return nil }
        let index = package.spineURLs.firstIndex(of: first.url)
        let title = toc.first(where: { $0.absoluteURL.standardizedFileURL.path == first.url.standardizedFileURL.path })?.title ?? "Start Reading"
        return TOCNode(title: title, url: first.url, children: [], spineIndex: index, isLandmark: false)
    }

    func firstSpineIndex(afterCoverIn package: EPUBPackage) -> Int? {
        guard let cover = package.landmarks.first(where: { $0.type == "cover" }),
              let coverIndex = package.spineURLs.firstIndex(where: {
                  $0.standardizedFileURL.path == cover.url.standardizedFileURL.path
              })
        else { return nil }
        return package.spine.indices.first(where: { $0 > coverIndex && package.spine[$0].isLinear })
    }

    private func heading(in url: URL) -> String? {
        guard let source = try? String(contentsOf: url, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(?is)<h[1-3][^>]*>(.*?)</h[1-3]>"#),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File Discovery

    private func findNCX(in root: URL) -> URL? {
        let fm = FileManager.default
        for candidate in ["toc.ncx", "OEBPS/toc.ncx", "OPS/toc.ncx"] {
            let url = root.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent.lowercased() == "toc.ncx" {
                return url
            }
        }
        return nil
    }

    private func findNav(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        let validExtensions = ["xhtml", "html", "htm"]
        let validBases = ["nav", "navigation", "toc"]

        for case let url as URL in enumerator {
            guard validExtensions.contains(url.pathExtension.lowercased()),
                  validBases.contains(url.deletingPathExtension().lastPathComponent.lowercased()),
                  let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  content.localizedCaseInsensitiveContains("<nav")
            else { continue }
            return url
        }
        return nil
    }

    // MARK: - NCX Parser (EPUB 2)

    private func parseNCX(at url: URL, rootFolder: URL) -> [TOCEntry]? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? XMLDocument(data: data),
              let navPoints = (try? doc.nodes(forXPath: "//*[local-name()='navMap']/*[local-name()='navPoint']")) as? [XMLElement],
              !navPoints.isEmpty
        else { return nil }

        var order = 0
        return parseNCXPoints(
            navPoints, doc: doc, rootFolder: rootFolder, rootURL: url.deletingLastPathComponent(), depth: 0, order: &order
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func parseNCXPoints(
        _ nodes: [XMLElement], doc: XMLDocument, rootFolder: URL, rootURL: URL, depth: Int, order: inout Int
    ) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        for node in nodes {
            guard let titleNode = (try? node.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?.first,
                  let contentNode = (try? node.nodes(forXPath: "*[local-name()='content']"))?.first as? XMLElement,
                  let src = contentNode.attribute(forName: "src")?.stringValue
            else { continue }

            let title = (titleNode.stringValue ?? "Untitled")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            let decoded = src.removingPercentEncoding ?? src
            let absURL = resolveLocalURL(src, relativeTo: rootURL)

            order += 1
            let currentOrder = order

            let childNodes = (try? node.nodes(forXPath: "*[local-name()='navPoint']")) as? [XMLElement] ?? []
            let children = parseNCXPoints(
                childNodes, doc: doc, rootFolder: rootFolder, rootURL: rootURL, depth: depth + 1, order: &order
            )

            entries.append(TOCEntry(
                title: title.isEmpty ? "Untitled" : title,
                href: decoded,
                absoluteURL: absURL,
                playOrder: currentOrder,
                depth: depth,
                children: children
            ))
        }
        return entries
    }

    // MARK: - Nav Parser (EPUB 3)

    private func parseNav(at url: URL, rootFolder: URL) -> [TOCEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let xmlEntries = parseXMLNav(data: data, baseURL: url.deletingLastPathComponent()), !xmlEntries.isEmpty {
            return xmlEntries
        }
        guard let src = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parseSoupNav(source: src, baseURL: url.deletingLastPathComponent())
    }

    private func parseXMLNav(data: Data, baseURL: URL) -> [TOCEntry]? {
        guard let doc = try? XMLDocument(data: data),
              let navs = try? doc.nodes(forXPath: "//*[local-name()='nav']") as? [XMLElement]
        else { return nil }

        let tocNav = navs.first { element in
            guard let type = element.attributes?.first(where: { $0.localName == "type" })?.stringValue?.lowercased() else { return false }
            return type.split(whereSeparator: \.isWhitespace).contains("toc")
        } ?? navs.first { element in
            element.attributes?.first(where: { $0.localName == "type" }) == nil
        }

        guard let tocNav else { return nil }

        if let lists = try? tocNav.nodes(forXPath: "./*[local-name()='ol']") as? [XMLElement],
           let list = lists.first {
            var order = 0
            let entries = parseNavList(list, base: baseURL, depth: 0, order: &order)
            if !entries.isEmpty { return entries }
        }

        let links = (try? tocNav.nodes(forXPath: ".//*[local-name()='a']")) as? [XMLElement] ?? []
        var entries: [TOCEntry] = []
        var order = 0
        for link in links {
            guard let href = link.attribute(forName: "href")?.stringValue,
                  !href.isEmpty, !href.hasPrefix("#") else { continue }
            let title = link.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }
            order += 1
            entries.append(TOCEntry(
                title: title, href: href.removingPercentEncoding ?? href,
                absoluteURL: resolveLocalURL(href, relativeTo: baseURL), playOrder: order, depth: 0
            ))
        }
        return entries.isEmpty ? nil : entries
    }

    private func parseNavList(_ list: XMLElement, base: URL, depth: Int, order: inout Int) -> [TOCEntry] {
        let items = (try? list.nodes(forXPath: "./*[local-name()='li']")) as? [XMLElement] ?? []
        return items.compactMap { item in
            guard let link = (try? item.nodes(forXPath: "./*[local-name()='a']"))?.first as? XMLElement,
                  let href = link.attribute(forName: "href")?.stringValue
            else { return nil }
            let title = link.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, !href.hasPrefix("#") else { return nil }
            order += 1
            let currentOrder = order
            let childLists = (try? item.nodes(forXPath: "./*[local-name()='ol']")) as? [XMLElement] ?? []
            let children = childLists.flatMap { parseNavList($0, base: base, depth: depth + 1, order: &order) }
            let decoded = href.removingPercentEncoding ?? href
            return TOCEntry(
                title: title, href: decoded, absoluteURL: resolveLocalURL(href, relativeTo: base),
                playOrder: currentOrder, depth: depth, children: children
            )
        }
    }

    private func parseSoupNav(source: String, baseURL: URL) -> [TOCEntry]? {
        guard let soupDoc = try? Parser.htmlParser().parseInput(source, ""),
              let soupNavs = try? soupDoc.select("nav"), !soupNavs.isEmpty
        else { return nil }

        let targetNav = soupNavs.first { nav in
            let epubType = (try? nav.attr("epub:type"))?.lowercased() ?? ""
            let type = (try? nav.attr("type"))?.lowercased() ?? ""
            return (epubType + " " + type).split(whereSeparator: \.isWhitespace).contains("toc")
        } ?? soupNavs.first { nav in
            let epubType = (try? nav.attr("epub:type")) ?? ""
            let type = (try? nav.attr("type")) ?? ""
            return epubType.isEmpty && type.isEmpty
        }
        guard let targetNav else { return nil }

        if let ol = try? targetNav.select("ol").first() {
            var order = 0
            let entries = parseSoupNavList(ol, base: baseURL, depth: 0, order: &order)
            return entries.isEmpty ? nil : entries
        }
        return parseSoupFlatLinks(targetNav, base: baseURL)
    }

    private func parseSoupFlatLinks(_ nav: Element, base: URL) -> [TOCEntry]? {
        guard let links = try? nav.select("a[href]") else { return nil }
        var entries: [TOCEntry] = []
        var order = 0
        for link in links {
            guard let href = try? link.attr("href"), !href.isEmpty, !href.hasPrefix("#") else { continue }
            let title = ((try? link.text()) ?? "")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard !title.isEmpty else { continue }
            order += 1
            entries.append(TOCEntry(
                title: title, href: href.removingPercentEncoding ?? href,
                absoluteURL: resolveLocalURL(href, relativeTo: base), playOrder: order, depth: 0
            ))
        }
        return entries.isEmpty ? nil : entries
    }

    private func parseSoupNavList(_ list: Element, base: URL, depth: Int, order: inout Int) -> [TOCEntry] {
        guard let items = try? list.children().filter({ $0.tagName().lowercased() == "li" }) else { return [] }
        var entries: [TOCEntry] = []
        for item in items {
            guard let link = try? item.select("> a").first() ?? item.select("a").first(),
                  let href = try? link.attr("href"), !href.isEmpty, !href.hasPrefix("#")
            else { continue }
            let title = ((try? link.text()) ?? "")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard !title.isEmpty else { continue }

            order += 1
            let currentOrder = order

            var children: [TOCEntry] = []
            if let childOl = try? item.select("> ol").first() ?? item.select("ol").first() {
                children = parseSoupNavList(childOl, base: base, depth: depth + 1, order: &order)
            }

            entries.append(TOCEntry(
                title: title,
                href: href.removingPercentEncoding ?? href,
                absoluteURL: resolveLocalURL(href, relativeTo: base),
                playOrder: currentOrder,
                depth: depth,
                children: children
            ))
        }
        return entries
    }

    // MARK: - Spine Synthesis Fallback

    static func fallbackTitle(forFileNamed name: String, spineIndex: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Chapter \(spineIndex + 1)" }

        let pattern = #"^([A-Za-z]+)[ _-]*0*([0-9]+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let prefixRange = Range(match.range(at: 1), in: trimmed),
           let digitsRange = Range(match.range(at: 2), in: trimmed) {
            let prefix = String(trimmed[prefixRange]).capitalized
            let digits = String(trimmed[digitsRange])
            let num = Int(digits) ?? 0
            return "\(prefix) \(num)"
        }
        if trimmed.allSatisfy(\.isNumber) {
            return "Section \(spineIndex + 1)"
        }
        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func synthesiseFromSpine(_ pkg: EPUBPackage) -> [TOCEntry] {
        pkg.spineURLs.enumerated().map { i, url in
            let name = url.deletingPathExtension().lastPathComponent
            let title = Self.fallbackTitle(forFileNamed: name, spineIndex: i)
            return TOCEntry(
                title: title, href: url.lastPathComponent, absoluteURL: url, playOrder: i + 1, depth: 0
            )
        }
    }

    private func resolveLocalURL(_ href: String, relativeTo base: URL) -> URL {
        guard let source = URLComponents(string: href) else {
            let path = href.components(separatedBy: "#").first ?? href
            return URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base).standardizedFileURL
        }
        let path = source.percentEncodedPath.removingPercentEncoding ?? source.path
        let fileURL = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        guard var resolved = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return fileURL }
        resolved.query = source.query
        resolved.fragment = source.fragment
        return resolved.url ?? fileURL
    }
}
