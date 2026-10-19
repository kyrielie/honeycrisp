import Foundation

struct SourceProfile {
    let css: String

    static func forGenerator(_ generator: BookGenerator) -> SourceProfile? {
        let common = [.ao3Native, .ficlab, .fichub, .webToEpub].contains(generator)
            ? "p.hc-spacer{display:none !important;}\n"
            : ""
        let specific: String
        switch generator {
        case .gutenberg:
            specific = ".pagenum,.sidenote{font-size:.75em !important;opacity:.55 !important;}\n"
        case .standardEbooks:
            specific = "p span.i1{padding-left:2em !important;}p span.i2{padding-left:3em !important;}\n"
        case .wikisource:
            specific = ".wst-dhr{visibility:visible !important;}\n"
        default:
            specific = ""
        }
        guard !common.isEmpty || !specific.isEmpty else { return nil }
        return SourceProfile(css: common + specific)
    }

    static func tagFanficSpacerParagraphs(in html: String, generator: BookGenerator) -> String {
        guard [.ao3Native, .ficlab, .fichub, .webToEpub].contains(generator),
              let regex = try? NSRegularExpression(
                pattern: #"(?is)<p\b([^>]*)>((?:(?:\s|&nbsp;|&#160;|&#x0*a0;|&#x0*00a0;)|\u00a0)*)</p\s*>"#
              )
        else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var output = html
        for match in matches.reversed() {
            let attrs = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            guard !body.isEmpty else { continue }
            let replacement: String
            if let classMatch = attrs.range(of: #"(?i)class\s*=\s*([\"'])(.*?)\1"#, options: .regularExpression) {
                var updated = attrs
                let current = String(attrs[classMatch])
                let value = current.replacingOccurrences(of: #"(?i)^class\s*=\s*([\"'])(.*?)\1$"#, with: "$2", options: .regularExpression)
                updated.replaceSubrange(classMatch, with: "class=\"\(value) hc-spacer\"")
                replacement = "<p\(updated)>\(body)</p>"
            } else {
                replacement = "<p\(attrs) class=\"hc-spacer\">\(body)</p>"
            }
            if let range = Range(match.range, in: output) { output.replaceSubrange(range, with: replacement) }
        }
        return output
    }
}

