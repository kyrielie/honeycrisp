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

final class TOCParser {

    /// Attempts NCX first, falls back to nav.xhtml
    func parseTOC(for pkg: EPUBPackage) -> [TOCEntry] {
        let root = pkg.rootFolder

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
            let absURL = URL(fileURLWithPath: decoded, relativeTo: rootURL).standardizedFileURL

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
        guard let data = try? Data(contentsOf: url),
              let src = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }

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
            let absURL = URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
            order += 1
            entries.append(TOCEntry(title: title, href: decoded, absoluteURL: absURL, playOrder: order, depth: 0))
        }
        return entries.isEmpty ? nil : entries
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
}
