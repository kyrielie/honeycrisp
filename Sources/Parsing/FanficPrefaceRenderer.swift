import Foundation

enum FanficPrefaceRenderer {
    static func html(id: String = "ao3Preface", data: WorkMeta, includeTitleBlock: Bool = true) -> String {
        var output = "<div id='\(escapeAttribute(id))' class='hc-preface'>"
        if includeTitleBlock {
            output += "<h1 class='heading'>\(escape(data.title))</h1>"
            if !data.authors.isEmpty {
                output += "<div class='byline'>by "
                output += data.authors.map { author in
                    if let url = safeHTTP(author.url) {
                        return "<a rel='author' href='\(escapeAttribute(url.absoluteString))'>\(escape(author.name))</a>"
                    }
                    return escape(author.name)
                }.joined(separator: ", ")
                output += "</div>"
            }
        }
        if let site = data.siteLabel, let source = safeHTTP(data.sourceURL) {
            output += "<p class='message'>Posted originally on the <a href='\(escapeAttribute(siteURL(for: data.siteLabel)))'>\(escape(site))</a> at <a href='\(escapeAttribute(source.absoluteString))'>\(escape(source.absoluteString))</a>.</p>"
        }
        output += "<dl class='tags'>"
        for row in data.rows {
            let kind = row.kind.map { " data-kind='\(escapeAttribute($0))'" } ?? ""
            let wide = row.isWide ? " class='wide'" : ""
            let dtWide = row.isWide ? " class='wide'" : ""
            output += "<dt\(dtWide)\(kind)>\(escape(row.label)):</dt><dd\(wide)\(kind)>"
            output += row.values.map { value in
                if let href = safeHTTP(value.href) {
                    let category = row.kind == "category" ? categorySlug(value.text).map { " data-value='\($0)'" } ?? "" : ""
                    return "<a\(category) href='\(escapeAttribute(href.absoluteString))'>\(escape(value.text))</a>"
                }
                let category = row.kind == "category" ? categorySlug(value.text).map { " data-value='\($0)'" } ?? "" : ""
                return category.isEmpty ? escape(value.text) : "<span\(category)>\(escape(value.text))</span>"
            }.joined(separator: ", ")
            output += "</dd>"
        }
        for stat in data.stats {
            output += "<dt>\(escape(stat.label)):</dt><dd>\(escape(stat.value))</dd>"
        }
        output += "</dl>"
        if let summary = data.summaryHTML {
            output += "<div class='summary module'><h3 class='heading'>Summary:</h3><blockquote class='userstuff'>\(WorkMetaExtractor.sanitize(summary))</blockquote></div>"
        }
        if let notes = data.notesHTML {
            output += "<div class='notes module'><h3 class='heading'>Notes:</h3><blockquote class='userstuff'>\(WorkMetaExtractor.sanitize(notes))</blockquote></div>"
        }
        return output + "</div>"
    }

    private static func safeHTTP(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private static func siteURL(for label: String?) -> String {
        switch label {
        case "Archive of Our Own": return "https://archiveofourown.org/"
        case "FanFiction.net": return "https://www.fanfiction.net/"
        case "Fimfiction": return "https://www.fimfiction.net/"
        default: return "https://\(URL(string: "https://" + (label ?? ""))?.host ?? "example.invalid")/"
        }
    }

    private static func categorySlug(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "f/f", "f-f": return "ff"
        case "f/m", "f-m": return "fm"
        case "m/m", "m-m": return "mm"
        case "gen", "general": return "gen"
        case "multi": return "multi"
        case "other": return "other"
        default: return nil
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "'", with: "&#39;")
    }
}

