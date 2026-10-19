import Foundation

enum BookGenerator: String, Equatable {
    case ao3Native, ficlab, fichub, webToEpub, gutenberg, standardEbooks, wikisource, unknown
}

enum BookSite: Equatable {
    case ao3, fanfictionNet, fimfiction, host(String)

    var label: String {
        switch self {
        case .ao3: return "Archive of Our Own"
        case .fanfictionNet: return "FanFiction.net"
        case .fimfiction: return "Fimfiction"
        case .host(let value): return value
        }
    }

    static func from(_ raw: String?) -> BookSite? {
        guard let raw, let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        if host == "archiveofourown.org" || host.hasSuffix(".archiveofourown.org") { return .ao3 }
        if host == "fanfiction.net" || host.hasSuffix(".fanfiction.net") { return .fanfictionNet }
        if host == "fimfiction.net" || host.hasSuffix(".fimfiction.net") { return .fimfiction }
        return .host(host)
    }
}

struct BookIdentity: Equatable {
    let generator: BookGenerator
    let site: BookSite?
    let sourceURL: URL?

    static func detect(_ package: EPUBPackage) -> BookIdentity {
        let source = package.metadata["source"]?.first
            ?? package.metadata["identifier"]?.first(where: { $0.lowercased().hasPrefix("url:") })?.dropFirst(4).description
            ?? firstSourceText(in: package)
        let sourceURL = source.flatMap(URL.init(string:))
        let docs = package.spineURLs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let firstTwo = docs.prefix(2).joined(separator: " ")
        let all = docs.joined(separator: " ")
        let lower = all.lowercased()
        let publisher = package.metadata["publisher"]?.joined(separator: " ").lowercased() ?? ""
        let identifiers = package.metadata["identifier"]?.joined(separator: " ").lowercased() ?? ""
        let generator: BookGenerator
        if firstTwo.localizedCaseInsensitiveContains("Exported with the assistance of FicHub") {
            generator = .fichub
        } else if identifiers.contains("ficlab:") || lower.contains("class=\"fl-title\"") || lower.contains("class=\"fl-summary\"") || lower.contains("class=\"fl-cover\"") {
            generator = .ficlab
        } else if lower.contains("dl class=\"work meta group\"") || lower.contains("dl class='work meta group'") {
            generator = .webToEpub
        } else if let first = docs.first, first.lowercased().contains("id=\"preface\""),
                  (first.lowercased().contains("class=\"tags\"") || first.localizedCaseInsensitiveContains("Posted originally on")),
                  publisher.contains("archive of our own") {
            generator = .ao3Native
        } else if (sourceURL?.host?.lowercased().contains("gutenberg.org") == true) || lower.contains("pg-boilerplate") {
            generator = .gutenberg
        } else if publisher.contains("standard ebooks") || identifiers.contains("standardebooks.org") {
            generator = .standardEbooks
        } else if sourceURL?.host?.lowercased().hasSuffix("wikisource.org") == true {
            generator = .wikisource
        } else {
            generator = .unknown
        }
        return BookIdentity(generator: generator, site: BookSite.from(source), sourceURL: sourceURL)
    }

    private static func firstSourceText(in package: EPUBPackage) -> String? {
        for url in package.spineURLs {
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  let regex = try? NSRegularExpression(pattern: #"(?is)Original source:\s*(https?://[^\s<]+)|Posted originally on.{0,300}?\bat\s+(https?://[^\s<]+)"#),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
            else { continue }
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: source) { return String(source[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)")) }
            }
        }
        return nil
    }
}

