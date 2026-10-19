import Foundation

enum WorkMetaExtractor {
    static func extract(from package: EPUBPackage, identity: BookIdentity? = nil) -> WorkMeta? {
        let identity = identity ?? BookIdentity.detect(package)
        guard [.ao3Native, .ficlab, .fichub, .webToEpub].contains(identity.generator) else { return nil }
        let documents = package.spineURLs.map { parseHTML($0) }
        let title = package.metadata["title"]?.first ?? package.title
        let creatorValues = package.metadata["creator"] ?? []
        let authorNodes = documents.flatMap { document in
            (try? document?.nodes(forXPath: "//*[local-name()='a'][@rel='author']"))?.compactMap { $0 as? XMLElement } ?? []
        }
        var authors = authorNodes.compactMap { node -> Person? in
            let name = clean(node.stringValue)
            guard !name.isEmpty else { return nil }
            return Person(name: name, url: node.attribute(forName: "href")?.stringValue.flatMap(URL.init(string:)))
        }
        if authors.isEmpty {
            authors = creatorValues.map { Person(name: $0, url: nil) }
        }
        if authors.isEmpty, identity.generator == .fichub {
            for url in package.spineURLs {
                guard let source = try? String(contentsOf: url, encoding: .utf8),
                      let regex = try? NSRegularExpression(pattern: #"(?is)By:\s*([^<\r\n]+)"#),
                      let text = Optional(source),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[range]).components(separatedBy: "Status:").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { continue }
                authors = [Person(name: name, url: nil)]
                break
            }
        }
        guard !title.isEmpty, !authors.isEmpty else { return nil }

        var rows: [WorkMeta.Row] = []
        var summary: String?
        var notes: String?
        var stats: [(label: String, value: String)] = []
        for document in documents.compactMap({ $0 }) {
            let pairs = (try? document.nodes(forXPath: "//*[local-name()='dl']/*[local-name()='dt']")) as? [XMLElement] ?? []
            for dt in pairs {
                guard let dd = nextElementSibling(of: dt), (dd.localName ?? dd.name ?? "").lowercased() == "dd" else { continue }
                let label = clean(dt.stringValue).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                guard !label.isEmpty else { continue }
                if label.caseInsensitiveCompare("Stats") == .orderedSame {
                    stats.append(contentsOf: parseStats(clean(dd.stringValue)))
                    continue
                }
                let values = (try? dd.nodes(forXPath: ".//*[local-name()='a']"))?.compactMap { node -> WorkMeta.Row.Value? in
                    guard let link = node as? XMLElement else { return nil }
                    let text = clean(link.stringValue)
                    return text.isEmpty ? nil : WorkMeta.Row.Value(text: text, href: link.attribute(forName: "href")?.stringValue.flatMap(URL.init(string:)))
                } ?? []
                let rowValues = values.isEmpty
                    ? [WorkMeta.Row.Value(text: clean(dd.stringValue), href: nil)]
                    : values
                if rowValues.allSatisfy({ $0.text.isEmpty }) { continue }
                rows.append(.init(label: label, values: rowValues, isWide: ["fandom", "relationships", "characters", "additional tags", "archive warning"].contains(label.lowercased()), kind: kind(for: label)))
            }
            if summary == nil {
                let blocks = (try? document.nodes(forXPath: "//*[contains(concat(' ', normalize-space(@class), ' '), ' userstuff ')]")) ?? []
                if let first = blocks.first { summary = sanitize(first.children?.map { $0.xmlString }.joined() ?? "") }
                if blocks.count > 1 { notes = sanitize(blocks[1].children?.map { $0.xmlString }.joined() ?? "") }
            }
            if summary == nil, identity.generator == .fichub {
                let paragraphs = (try? document.nodes(forXPath: "//*[local-name()='p']")) ?? []
                let candidate = paragraphs.first { node in
                    let text = clean(node.stringValue).lowercased()
                    return !text.isEmpty && !text.hasPrefix("by:") && !text.hasPrefix("status:") &&
                        !text.hasPrefix("published:") && !text.hasPrefix("updated:") &&
                        !text.hasPrefix("words:") && !text.contains("exported with the assistance") &&
                        !text.hasPrefix("original source:")
                }
                if let candidate { summary = sanitize(candidate.children?.map { $0.xmlString }.joined() ?? candidate.stringValue ?? "") }
                for paragraph in paragraphs {
                    stats.append(contentsOf: parseStats(clean(paragraph.stringValue)))
                }
            }
        }
        if rows.isEmpty {
            for tag in package.metadata["subject"] ?? [] where !["fanworks", "fanfiction"].contains(tag.lowercased()) {
                rows.append(.init(label: "Tags", values: [.init(text: tag, href: nil)], isWide: false, kind: "freeform"))
            }
        }
        if let description = package.metadata["description"]?.first, summary == nil {
            summary = sanitize(EPUBParser.decodeHTMLEntities(description))
        }
        if identity.generator == .ficlab {
            for (key, label) in [("issued", "Published"), ("modified", "Updated")] {
                if let value = package.metadata[key]?.first {
                    stats.append((label, String(value.prefix(10))))
                }
            }
        }
        guard !rows.isEmpty || summary != nil || notes != nil || !stats.isEmpty || identity.sourceURL != nil else { return nil }
        return WorkMeta(title: title, authors: authors, siteLabel: identity.site?.label, sourceURL: identity.sourceURL,
                        summaryHTML: summary, notesHTML: notes, rows: rows, stats: stats)
    }

    private static func parseHTML(_ url: URL) -> XMLDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? XMLDocument(data: data, options: [.documentTidyXML])) ?? (try? XMLDocument(data: data))
    }

    private static func clean(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nextElementSibling(of node: XMLNode) -> XMLElement? {
        var sibling = node.nextSibling
        while let current = sibling {
            if let element = current as? XMLElement { return element }
            sibling = current.nextSibling
        }
        return nil
    }

    private static func kind(for label: String) -> String? {
        switch label.lowercased() {
        case "rating": return "rating"
        case "archive warning": return "warning"
        case "category": return "category"
        case "fandom": return "fandom"
        case "relationships": return "relationship"
        case "characters": return "character"
        case "additional tags": return "freeform"
        case "language": return "language"
        case "series": return "series"
        case "collections": return "collections"
        default: return nil
        }
    }

    private static func parseStats(_ text: String) -> [(label: String, value: String)] {
        let labels = ["Rated", "Language", "Genre", "Characters", "Status", "Published", "Updated", "Words", "Chapters", "Comments", "Kudos", "Bookmarks", "Hits", "Reviews", "Favs", "Follows"]
        let alternatives = labels.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(\b(?:\#(alternatives))\s*:\s*)(.*?)(?=\s+-?\s*\b(?:\#(alternatives))\s*:|$)"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let label = ns.substring(with: match.range(at: 1)).components(separatedBy: ":").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : (label, value)
        }
    }

    static func sanitize(_ html: String) -> String {
        let allowed = Set(["p", "br", "em", "strong", "i", "b", "u", "s", "blockquote", "ul", "ol", "li", "hr", "a"])
        let source = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        // XML nodes are emitted by Foundation; only a narrow tag set survives.
        guard let doc = try? XMLDocument(xmlString: "<root>\(source)</root>", options: [.documentTidyXML]),
              let root = doc.rootElement() else { return html.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression) }
        func emit(_ node: XMLNode) -> String {
            guard let element = node as? XMLElement else {
                guard let string = node.stringValue else { return "" }
                return escape(string)
            }
            let tag = (element.localName ?? element.name ?? "").lowercased()
            let body = element.children?.map(emit).joined() ?? ""
            guard allowed.contains(tag) else { return body }
            if tag == "br" || tag == "hr" { return "<\(tag)/>" }
            if tag == "a", let href = element.attribute(forName: "href")?.stringValue,
               let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return "<a href='\(escapeAttribute(href))' rel='noopener noreferrer'>\(body)</a>"
            }
            return "<\(tag)>\(body)</\(tag)>"
        }
        return root.children?.map(emit).joined() ?? ""
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "'", with: "&#39;")
    }
}

