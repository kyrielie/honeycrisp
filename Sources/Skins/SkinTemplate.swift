import Foundation

enum SkinTemplate {
    static let defaultTemplate = #"<div id="bodyContainer" class="articleBody">[[body]]</div>"#
    static let avatarPlaceholder = "data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs="

    private static let macros: Set<String> = [
        "body", "byline", "title", "preferred_link", "text_size_class", "feed_link", "feed_link_title",
        "date_medium", "datetime_long", "dateline_style", "datetime_medium", "external_link",
        "external_link_label", "external_link_stripped", "time_medium", "time_long", "avatar_src"
    ]

    static func render(_ source: String, body: String, title: String, author: String, sourceURL: URL?, siteLabel: String?, date: String? = nil) -> String {
        let template = sanitize(source)
        let titleValue = escape(title)
        let byline = author.isEmpty ? "" : "<span class='byline'>\(escape(author))</span>"
        let link = sourceURL.flatMap(safeHTTP)?.absoluteString ?? "#"
        let escapedLink = escapeAttribute(link)
        let formattedDate = date.map { String($0.prefix(10)) } ?? ""
        var values: [String: String] = [
            "body": body, "title": titleValue, "byline": byline, "preferred_link": escapedLink,
            "feed_link": escapedLink, "feed_link_title": escape(siteLabel ?? ""),
            "date_medium": escape(formattedDate), "datetime_long": escape(formattedDate), "dateline_style": "articleDatelineTitle",
            "datetime_medium": escape(formattedDate), "external_link": link == "#" ? "" : escapedLink,
            "external_link_label": link == "#" ? "" : "Source",
            "external_link_stripped": escape(link.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)),
            "time_medium": "", "time_long": "", "avatar_src": avatarPlaceholder, "text_size_class": ""
        ]
        let pattern = #"\[\[([A-Za-z0-9_-]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return defaultTemplate.replacingOccurrences(of: "[[body]]", with: body) }
        let source = template as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let macro = source.substring(with: match.range(at: 1))
            output += macros.contains(macro) ? (values[macro] ?? "") : ""
            cursor = NSMaxRange(match.range)
        }
        output += source.substring(from: cursor)
        return output
    }

    static func sanitize(_ source: String) -> String {
        guard source.utf8.count <= 16_384 else { return defaultTemplate }
        var template = source.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        template = template.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script\s*>"#, with: "", options: .regularExpression)
        if template.range(of: #"(?i)<script\b"#, options: .regularExpression) != nil { return defaultTemplate }
        let forbidden = [#"<\s*(iframe|object|embed|link|style|meta|base)\b"#, #"\son[a-z]+\s*="#, #"(?i)javascript\s*:"#,
                         #"(?i)data\s*:"#]
        if forbidden.contains(where: { template.range(of: $0, options: .regularExpression) != nil }) { return defaultTemplate }
        if let srcRegex = try? NSRegularExpression(pattern: #"(?i)\bsrc\s*=\s*([\"'])(.*?)\1"#) {
            let ns = template as NSString
            for match in srcRegex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range(at: 2))
                if value != "[[avatar_src]]" { return defaultTemplate }
            }
        }
        if let hrefRegex = try? NSRegularExpression(pattern: #"(?i)\bhref\s*=\s*([\"'])(.*?)\1"#) {
            let ns = template as NSString
            for match in hrefRegex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range(at: 2))
                if value.hasPrefix("#") || value.range(of: #"^\[\[[A-Za-z0-9_-]+\]\]$"#, options: .regularExpression) != nil { continue }
                guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return defaultTemplate }
            }
        }
        let body = template.range(of: #"<([A-Za-z][^>]*\bid\s*=\s*([\"'])bodyContainer\2[^>]*\bclass\s*=\s*([\"'])[^\"']*articleBody[^\"']*\3[^>]*)>[\s\S]*?\[\[body\]\][\s\S]*?</[A-Za-z][^>]*>"#, options: .regularExpression) != nil
        return body ? template : defaultTemplate
    }

    private static func safeHTTP(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeAttribute(_ value: String) -> String { escape(value).replacingOccurrences(of: "\"", with: "&quot;") }
}

