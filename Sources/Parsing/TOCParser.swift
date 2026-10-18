// TOCParser.swift
// Parses EPUB Table of Contents from toc.ncx or nav.xhtml

import Foundation

struct TOCEntry: Identifiable {
    let id: UUID
    let title: String
    let href: String          // relative path, possibly with fragment  e.g. "Text/chapter1.xhtml#section2"
    let absoluteURL: URL      // resolved against rootFolder
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

        // 1. Try toc.ncx (EPUB 2)
        if let ncxURL = findNCX(in: root),
           let entries = parseNCX(at: ncxURL, rootFolder: root), !entries.isEmpty {
            return entries
        }

        // 2. Try nav.xhtml (EPUB 3)
        if let navURL = findNav(in: root),
           let entries = parseNav(at: navURL, rootFolder: root), !entries.isEmpty {
            return entries
        }

        // 3. Synthesise from spine as a last resort
        return synthesiseFromSpine(pkg)
    }

    func tocNodes(for entries: [TOCEntry], package: EPUBPackage) -> [TOCNode] {
        func convert(_ entry: TOCEntry) -> TOCNode {
            let base = entry.absoluteURL.standardizedFileURL
            let index = package.spineURLs.firstIndex { $0.standardizedFileURL.path == base.path }
            return TOCNode(title: entry.title, url: entry.absoluteURL, children: entry.children.map(convert), spineIndex: index, isLandmark: false)
        }
        return entries.map(convert)
    }

    func startReadingNode(in package: EPUBPackage, toc: [TOCEntry]) -> TOCNode? {
        if let landmark = package.landmarks.first(where: { ["bodymatter", "text"].contains($0.type.lowercased()) }),
           let index = package.spineURLs.firstIndex(where: { $0.standardizedFileURL.path == landmark.url.standardizedFileURL.path }) {
            return TOCNode(title: landmark.title.isEmpty ? "Start Reading" : landmark.title, url: landmark.url, children: [], spineIndex: index, isLandmark: true)
        }

        // Only skip an initial linear item when its filename/heading clearly
        // identifies it as front matter. Ambiguous first chapters remain the start.
        if let firstLinearIndex = package.spine.firstIndex(where: \.isLinear),
           let nextLinearIndex = package.spine.indices.first(where: { $0 > firstLinearIndex && package.spine[$0].isLinear }) {
            let first = package.spine[firstLinearIndex]
            let firstName = first.url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: "[_-]", with: " ", options: .regularExpression)
            let firstTitle = heading(in: first.url)?.lowercased() ?? ""
            let frontMatterTerms = ["cover", "title page", "contents", "table of contents"]
            let isLikelyFrontMatter = frontMatterTerms.contains(where: { firstName.contains($0) || firstTitle.contains($0) })
            if isLikelyFrontMatter {
                let next = package.spine[nextLinearIndex]
                return TOCNode(title: "Start Reading", url: next.url, children: [], spineIndex: nextLinearIndex, isLandmark: false)
            }
        }

        guard let first = package.spine.first(where: \.isLinear) ?? package.spine.first else { return nil }
        let index = package.spineURLs.firstIndex(of: first.url)
        let title = toc.first(where: { $0.absoluteURL.standardizedFileURL.path == first.url.standardizedFileURL.path })?.title ?? "Start Reading"
        return TOCNode(title: title, url: first.url, children: [], spineIndex: index, isLandmark: false)
    }

    /// Returns the next linear spine document only when EPUB navigation names
    /// an explicit cover landmark. A filename guess is not enough to omit a
    /// document from a user's reading start.
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
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File Discovery

    private func findNCX(in root: URL) -> URL? {
        let fm = FileManager.default
        // Common locations
        for candidate in ["toc.ncx", "OEBPS/toc.ncx", "OPS/toc.ncx"] {
            let u = root.appendingPathComponent(candidate)
            if fm.fileExists(atPath: u.path) { return u }
        }
        // Walk the tree
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in e {
                if u.lastPathComponent.lowercased() == "toc.ncx" { return u }
            }
        }
        return nil
    }

    private func findNav(in root: URL) -> URL? {
        let fm = FileManager.default
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in e {
                if u.lastPathComponent.lowercased().contains("nav") &&
                   ["xhtml", "html", "htm"].contains(u.pathExtension.lowercased()) {
                    return u
                }
            }
        }
        return nil
    }

    // MARK: - NCX Parser (EPUB 2)

    private func parseNCX(at url: URL, rootFolder: URL) -> [TOCEntry]? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? XMLDocument(data: data) else { return nil }

        // ✅ FIX: Only select direct children of navMap, not all navPoints in
        // the document. The old XPath `//*[local-name()='navPoint']` matched
        // every navPoint at every depth, causing children to appear both nested
        // (via recursion) and at the top level (via the initial flat list).
        let navPoints = (try? doc.nodes(forXPath:
            "//*[local-name()='navMap']/*[local-name()='navPoint']"
        )) as? [XMLElement] ?? []
        guard !navPoints.isEmpty else { return nil }

        var order = 0
        return parseNCXPoints(navPoints, doc: doc, rootFolder: rootFolder, rootURL: url.deletingLastPathComponent(), depth: 0, order: &order)
    }

    private func parseNCXPoints(_ nodes: [XMLElement], doc: XMLDocument, rootFolder: URL, rootURL: URL, depth: Int, order: inout Int) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        for node in nodes {
            guard let titleNode = (try? node.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?.first,
                  let contentNode = (try? node.nodes(forXPath: "*[local-name()='content']"))?.first as? XMLElement,
                  let src = contentNode.attribute(forName: "src")?.stringValue else { continue }

            let title = titleNode.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"
            let decoded = src.removingPercentEncoding ?? src
            let absURL = resolveLocalURL(src, relativeTo: rootURL)

            // ✅ FIX: Stamp the parent's playOrder before recursing into children
            // so ordering reflects document reading order (parent < children).
            // The old code incremented order after recursion, giving children
            // lower playOrder values than their parent.
            order += 1
            let currentOrder = order

            // Recurse into child navPoints
            let childNodes = (try? node.nodes(forXPath: "*[local-name()='navPoint']")) as? [XMLElement] ?? []
            let children = parseNCXPoints(childNodes, doc: doc, rootFolder: rootFolder, rootURL: rootURL, depth: depth + 1, order: &order)

            let entry = TOCEntry(title: title, href: decoded, absoluteURL: absURL, playOrder: currentOrder, depth: depth, children: children)
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Nav Parser (EPUB 3)

    private func parseNav(at url: URL, rootFolder: URL) -> [TOCEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let doc = try? XMLDocument(data: data),
           let navs = try? doc.nodes(forXPath: "//*[local-name()='nav']") as? [XMLElement],
           let nav = navs.first(where: { element in
               let type = element.attributes?.first(where: { $0.localName == "type" })?.stringValue?.lowercased()
               return type?.split(whereSeparator: \.isWhitespace).contains("toc") == true
           }) ?? navs.first,
           let lists = try? nav.nodes(forXPath: "./*[local-name()='ol']") as? [XMLElement],
           let list = lists.first {
            var order = 0
            let entries = parseNavList(list, base: url.deletingLastPathComponent(), depth: 0, order: &order)
            if !entries.isEmpty { return entries }
        }
        guard let src = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }

        // Quick regex-based extraction since XMLDocument chokes on HTML5
        let pattern = #"<a[^>]*\shref="([^"]*)"[^>]*>([\s\S]*?)<\/a>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }

        let ns = src as NSString
        let matches = re.matches(in: src, range: NSRange(src.startIndex..., in: src))
        var entries: [TOCEntry] = []
        var order = 0
        let base = url.deletingLastPathComponent()

        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let href = ns.substring(with: m.range(at: 1))
            var title = ns.substring(with: m.range(at: 2))
            // Strip inner tags
            title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                         .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty, !href.hasPrefix("#") else { continue }

            let decoded = href.removingPercentEncoding ?? href
            let absURL = resolveLocalURL(href, relativeTo: base)
            order += 1
            entries.append(TOCEntry(title: title, href: decoded, absoluteURL: absURL, playOrder: order, depth: 0))
        }
        return entries.isEmpty ? nil : entries
    }

    private func parseNavList(_ list: XMLElement, base: URL, depth: Int, order: inout Int) -> [TOCEntry] {
        let items = (try? list.nodes(forXPath: "./*[local-name()='li']")) as? [XMLElement] ?? []
        return items.compactMap { item in
            guard let link = (try? item.nodes(forXPath: "./*[local-name()='a']"))?.first as? XMLElement,
                  let href = link.attribute(forName: "href")?.stringValue else { return nil }
            let title = link.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            order += 1
            let currentOrder = order
            let childLists = (try? item.nodes(forXPath: "./*[local-name()='ol']")) as? [XMLElement] ?? []
            let children = childLists.flatMap { parseNavList($0, base: base, depth: depth + 1, order: &order) }
            let decoded = href.removingPercentEncoding ?? href
            return TOCEntry(title: title, href: decoded, absoluteURL: resolveLocalURL(href, relativeTo: base), playOrder: currentOrder, depth: depth, children: children)
        }
    }

    // MARK: - Spine Synthesis Fallback

    private func synthesiseFromSpine(_ pkg: EPUBPackage) -> [TOCEntry] {
        return pkg.spineURLs.enumerated().map { i, url in
            let name = url.deletingPathExtension().lastPathComponent
                          .replacingOccurrences(of: "_", with: " ")
                          .capitalized
            return TOCEntry(title: name.isEmpty ? "Chapter \(i + 1)" : name,
                            href: url.lastPathComponent,
                            absoluteURL: url,
                            playOrder: i + 1,
                            depth: 0)
        }
    }

    /// Resolve an EPUB-internal link while keeping query/fragment components
    /// out of the filesystem path. URL(fileURLWithPath:) treats `#fragment`
    /// as literal path text, which makes TOC jumps to anchors point at a
    /// nonexistent XHTML filename.
    private func resolveLocalURL(_ href: String, relativeTo base: URL) -> URL {
        guard let source = URLComponents(string: href) else {
            let path = href.components(separatedBy: "#").first ?? href
            return URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base).standardizedFileURL
        }

        let path = source.percentEncodedPath.removingPercentEncoding ?? source.path
        let fileURL = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        guard var resolved = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
            return fileURL
        }
        resolved.query = source.query
        resolved.fragment = source.fragment
        return resolved.url ?? fileURL
    }
}
