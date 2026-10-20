// EPUBParser.swift
// Parses EPUB files into structured content, adapted from the QuickLook plugin

// swiftlint:disable file_length
import Foundation
import AppKit
import ZIPFoundation

struct EPUBPackage {
    let rootFolder: URL
    let spineURLs: [URL]
    let title: String
    let author: String
    let coverURL: URL?
    let manifest: [String: EPUBManifestItem]
    let spine: [EPUBSpineItem]
    let version: String?
    let navigationURL: URL?
    let landmarks: [EPUBLandmark]
    let metadata: [String: [String]]

    init(
        rootFolder: URL, spineURLs: [URL], title: String, author: String, coverURL: URL?,
        manifest: [String: EPUBManifestItem] = [:], spine: [EPUBSpineItem]? = nil, version: String? = nil,
        navigationURL: URL? = nil, landmarks: [EPUBLandmark] = [], metadata: [String: [String]] = [:]
    ) {
        self.rootFolder = rootFolder
        self.spineURLs = spineURLs
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.manifest = manifest
        self.spine = spine ?? spineURLs.enumerated().map { EPUBSpineItem(manifestID: "spine-\($0.offset)", url: $0.element, isLinear: true) }
        self.version = version
        self.navigationURL = navigationURL
        self.landmarks = landmarks
        self.metadata = metadata
    }
}

struct EPUBManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: Set<String>
    let url: URL
}

struct EPUBSpineItem {
    let manifestID: String
    let url: URL
    let isLinear: Bool
}

struct EPUBLandmark {
    let type: String
    let title: String
    let url: URL
}

struct BookSearchResult {
    let spineIndex: Int
    let characterOffset: Int
    let excerpt: String
}

/// Snapshot of the reader's cosmetic settings (font, size, theme colors,
/// spacing, link clicks) at a single point in time -- everything
/// `EPUBParser.readerVarsCSS` needs. Passed explicitly into
/// buildScrollHTML/buildPageHTML at build time and reused as-is by
/// ReaderViewController.applyCosmeticCSSUpdate for its live JS patch, so both
/// paths are guaranteed to produce identical CSS from identical settings.
struct ReaderCosmeticSettings: Equatable {
    var fontSizePercent: Int
    var fontFamily: String
    var backgroundCSS: String
    var textCSS: String
    var linkCSS: String
    /// Search-hit palette (`ReaderContrast.hitColors`), emitted as `--reader-hit-*` so a theme change
    /// repaints hits through the live CSS patch without a reload.
    var hitBackground: String
    var hitText: String
    var hitActiveBackground: String
    var hitActiveText: String
    var lineHeight: Double
    var maxWidth: Int
    var paddingH: Int
    var paddingV: Int
    var paragraphIndent: Double
    var paragraphSpacing: Double
    var justify: Bool
    var hyphenate: Bool
    var allowLinkClicks: Bool
    /// The sanitized user overrides these values were resolved from. nil fields mean "the theme decides".
    /// Carried so the override stylesheet can emit rules only for what the user actually chose.
    var overrides: ReaderOverrides = .none

    /// Every value passes through `ReaderCSSSanitizer`, so the initial render and the live patch both
    /// get valid CSS no matter what is persisted. Hit colors derive from the sanitized page colors.
    static func current(from settings: SettingsManager, skin: ReaderSkin? = nil) -> ReaderCosmeticSettings {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return resolve(
            theme: skin ?? SkinStore.shared.skin(id: settings.readerSkinID),
            overrides: settings.readerOverrides,
            isDark: isDark,
            allowLinkClicks: settings.allowReaderLinkClicks,
            removeParagraphIndents: settings.removeParagraphIndents)
    }

    /// Pure resolution of theme + user overrides into concrete values: no `NSApp`, no
    /// `SettingsManager`, so the reader, the Settings preview and tests all share it.
    /// Precedence per value: user override, then the theme's token for the mode, then the baseline.
    /// `removeParagraphIndents` makes the indent 0 unless the user chose an explicit one.
    static func resolve(
        theme: ReaderSkin?,
        overrides rawOverrides: ReaderOverrides,
        isDark: Bool,
        allowLinkClicks: Bool,
        removeParagraphIndents: Bool = false
    ) -> ReaderCosmeticSettings {
        let overrides = rawOverrides.sanitized()
        let tokens = isDark ? (theme?.dark ?? theme?.light) : theme?.light
        let chosen = overrides.colors(isDark: isDark)
        let background = ReaderCSSSanitizer.hexColor(
            chosen.background ?? tokens?.background ?? ReaderBaseline.background,
            fallback: ReaderCSSSanitizer.fallbackBackground)
        let text = ReaderCSSSanitizer.hexColor(
            chosen.ink ?? tokens?.ink ?? ReaderBaseline.text,
            fallback: ReaderCSSSanitizer.fallbackText)
        let link = ReaderCSSSanitizer.hexColor(
            chosen.link ?? tokens?.link ?? ReaderBaseline.link,
            fallback: ReaderCSSSanitizer.fallbackLink)
        let hit = ReaderContrast.hitColors(background: background, text: text)
        return ReaderCosmeticSettings(
            fontSizePercent: overrides.fontSizePercent ?? ReaderBaseline.fontSizePercent,
            fontFamily: overrides.bodyFont ?? FontPresets.defaultStack,
            backgroundCSS: background,
            textCSS: text,
            linkCSS: link,
            hitBackground: hit.hitBackground,
            hitText: hit.hitText,
            hitActiveBackground: hit.activeBackground,
            hitActiveText: hit.activeText,
            lineHeight: overrides.lineHeight ?? ReaderBaseline.lineHeight,
            maxWidth: overrides.maxWidth ?? ReaderBaseline.maxWidth,
            paddingH: overrides.paddingH ?? ReaderBaseline.paddingH,
            paddingV: overrides.paddingV ?? ReaderBaseline.paddingV,
            paragraphIndent: overrides.paragraphIndent ?? (removeParagraphIndents ? 0 : ReaderBaseline.paragraphIndent),
            paragraphSpacing: overrides.paragraphSpacing ?? ReaderBaseline.paragraphSpacing,
            justify: overrides.justify ?? ReaderBaseline.justify,
            hyphenate: overrides.hyphenate ?? ReaderBaseline.hyphenate,
            allowLinkClicks: allowLinkClicks,
            overrides: overrides)
    }
}

enum EPUBParseError: Error, LocalizedError {
    case containerNotFound, opfNotFound, malformed, io, drmProtected

    var errorDescription: String? {
        switch self {
        case .containerNotFound: return "Could not find META-INF/container.xml"
        case .opfNotFound:       return "Could not locate the OPF package file"
        case .malformed:         return "EPUB spine is empty or malformed"
        case .io:                return "I/O error while reading EPUB"
        case .drmProtected:      return "This EPUB is protected (DRM) and can't be opened by Honeycrisp."
        }
    }
}

// swiftlint:disable:next type_body_length
final class EPUBParser: NSObject {

    static func javaScriptStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func unpackEPUB(at epubURL: URL, to workDir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: epubURL.path, isDirectory: &isDir), isDir.boolValue {
            let dest = workDir.appendingPathComponent("EPUBPackage", isDirectory: true)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.copyItem(at: epubURL, to: dest)
            return dest
        }

        try fm.unzipItem(at: epubURL, to: workDir)
        return workDir
    }

    /// `Algorithm` values that only obfuscate embedded fonts (IDPF and Adobe font obfuscation). These
    /// are not DRM: the book is otherwise readable.
    private static let fontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// True when the unpacked package carries a DRM marker. Matches by element local name (as
    /// `parseOPF` does), so namespace URIs are never needed. DRM if any of:
    /// 1. `META-INF/license.lcpl` exists (Readium LCP).
    /// 2. `encryption.xml` has `EncryptedData/KeyInfo/RetrievalMethod` with URI
    ///    `license.lcpl#/encryption/content_key` (LCP), or `EncryptedData/KeyInfo/resource` (ADEPT).
    /// 3. `encryption.xml` has any `EncryptionMethod` whose `Algorithm` is not a font-obfuscation id.
    ///    This catches unknown schemes the markers above would miss; it is broader than Readium's check.
    /// A missing, empty, or font-obfuscation-only `encryption.xml` is not DRM. An `encryption.xml` that
    /// cannot be parsed is also treated as not DRM: if the book is broken, the OPF or spine failure
    /// reports it as it would for any other broken book.
    static func isDRMProtected(extractedRoot: URL) -> Bool {
        let fm = FileManager.default
        let metaInf = extractedRoot.appendingPathComponent("META-INF", isDirectory: true)
        if fm.fileExists(atPath: metaInf.appendingPathComponent("license.lcpl").path) {
            return true
        }
        let encryptionURL = metaInf.appendingPathComponent("encryption.xml")
        guard let data = try? Data(contentsOf: encryptionURL),
            let document = try? XMLDocument(data: data)
        else { return false }

        let keyInfo = "//*[local-name()='EncryptedData']/*[local-name()='KeyInfo']"
        let markerPaths = [
            "\(keyInfo)/*[local-name()='RetrievalMethod'][@URI='license.lcpl#/encryption/content_key']",
            "\(keyInfo)/*[local-name()='resource']",
        ]
        for path in markerPaths {
            if let nodes = try? document.nodes(forXPath: path), !nodes.isEmpty { return true }
        }

        let methods = (try? document.nodes(forXPath: "//*[local-name()='EncryptionMethod']")) ?? []
        for case let method as XMLElement in methods {
            let algorithm = method.attribute(forName: "Algorithm")?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if algorithm.map({ !fontObfuscationAlgorithms.contains($0) }) ?? true { return true }
        }
        return false
    }

    func parsePackage(at extractedRoot: URL) throws -> EPUBPackage {
        let fm = FileManager.default

        // DRM-protected EPUBs (Adobe ADEPT, Readium LCP, most library-loan formats) are detected by
        // `isDRMProtected` (D3, D17). Checked first, before container.xml/OPF parsing, so a DRM'd file
        // gets a clear, specific error instead of falling through to .malformed/.opfNotFound once the
        // encrypted OPF or spine content fails to parse as plain XML/XHTML. A font-obfuscation-only
        // encryption.xml no longer counts.
        if Self.isDRMProtected(extractedRoot: extractedRoot) {
            throw EPUBParseError.drmProtected
        }

        let containerURL = extractedRoot.appendingPathComponent("META-INF/container.xml")

        if fm.fileExists(atPath: containerURL.path) {
            let containerData = try Data(contentsOf: containerURL)
            let container = try XMLDocument(data: containerData)
            if let rootAttr = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first,
               let opfPath = rootAttr.stringValue {
                let opfURL = extractedRoot.appendingPathComponent(opfPath)
                return try parseOPF(at: opfURL)
            }
        }

        if let enumerator = fm.enumerator(at: extractedRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "opf" {
                return try parseOPF(at: url)
            }
        }

        throw EPUBParseError.opfNotFound
    }

    /// `options` must be the same value the renderer uses (`ChapterRenderOptions.current(from:)`), so the
    /// offsets returned here line up with the DOM text. Capture it on the main thread before dispatching.
    func searchResults(
        for term: String, in package: EPUBPackage, limit: Int = 250,
        options: ChapterRenderOptions = .plain
    ) -> [BookSearchResult] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var results: [BookSearchResult] = []
        for index in package.spineURLs.indices {
            guard let html = try? Self.extractedChapterBody(
                from: package, index: index, base: package.rootFolder, options: options
            ) else { continue }
            let text = Self.searchableText(fromHTML: html)
            let nsText = text as NSString
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 && results.count < limit {
                let match = nsText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard match.location != NSNotFound else { break }
                let before = max(0, match.location - 65)
                let after = min(nsText.length, NSMaxRange(match) + 90)
                var excerpt = nsText.substring(with: NSRange(location: before, length: after - before))
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if before > 0 { excerpt = "…" + excerpt }
                if after < nsText.length { excerpt += "…" }
                results.append(BookSearchResult(spineIndex: index, characterOffset: match.location, excerpt: excerpt))
                let nextLocation = NSMaxRange(match)
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
            if results.count >= limit { break }
        }
        return results
    }

    func speechText(in package: EPUBPackage, at index: Int, options: ChapterRenderOptions = .plain) -> String? {
        guard package.spineURLs.indices.contains(index),
              let html = try? Self.extractedChapterBody(
                from: package,
                index: index,
                base: package.rootFolder,
                options: options
              ) else { return nil }
        let text = Self.searchableText(fromHTML: html)
        return text.isEmpty ? nil : text
    }

    /// Plain text of an HTML fragment as the offset-bearing features (search, speech) see it. Drops
    /// `<style>`/`<script>` content, removes tags, then decodes only the entities listed in
    /// `decodeHTMLEntities`. Emitted HTML must stay inside that set so DOM text and this text agree.
    static func searchableText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: "", options: .regularExpression)
        return decodeHTMLEntities(text)
    }

    // swiftlint:disable:next force_try
    private static let entityRegex = try! NSRegularExpression(
        pattern: #"&(?:#([0-9]+)|#x([0-9a-f]+)|(nbsp|amp|lt|gt|quot|apos));"#,
        options: [.caseInsensitive]
    )

    /// Decodes numeric references and `&nbsp; &amp; &lt; &gt; &quot; &apos;` in a single left-to-right
    /// pass, so `&amp;lt;` becomes the four characters `&lt;` (a sequential replace would decode it twice).
    /// Numeric references that are not valid Unicode scalars are dropped.
    static func decodeHTMLEntities(_ text: String) -> String {
        let ns = text as NSString
        let matches = entityRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let decimal = match.range(at: 1)
            let hex = match.range(at: 2)
            let named = match.range(at: 3)
            if decimal.location != NSNotFound {
                if let value = UInt32(ns.substring(with: decimal)), let scalar = UnicodeScalar(value) { out.unicodeScalars.append(scalar) }
            } else if hex.location != NSNotFound {
                if let value = UInt32(ns.substring(with: hex), radix: 16), let scalar = UnicodeScalar(value) { out.unicodeScalars.append(scalar) }
            } else if named.location != NSNotFound {
                switch ns.substring(with: named).lowercased() {
                case "nbsp": out += "\u{00a0}"
                case "amp": out += "&"
                case "lt": out += "<"
                case "gt": out += ">"
                case "quot": out += "\""
                default: out += "'"
                }
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func parseOPF(at opfURL: URL) throws -> EPUBPackage {
        let rootFolder = opfURL.deletingLastPathComponent()
        let opfData = try Data(contentsOf: opfURL)
        let opf = try XMLDocument(data: opfData)

        let titleNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']")).first as? XMLElement
        let authorNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']")).first as? XMLElement
        let bookTitle = titleNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bookAuthor = authorNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let metadataNodes = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*")) as? [XMLElement] ?? []
        var metadata: [String: [String]] = [:]
        for node in metadataNodes {
            let key = (node.localName ?? node.name ?? "").lowercased()
            if key == "meta", let metaName = node.attribute(forName: "name")?.stringValue?.lowercased(),
                let content = node.attribute(forName: "content")?.stringValue, !content.isEmpty
            {
                metadata[metaName, default: []].append(content)
            }
            let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, !value.isEmpty else { continue }
            metadata[key, default: []].append(value)
        }

        var hrefByID: [String: String] = [:]
        var mediaTypeByID: [String: String] = [:]
        var manifest: [String: EPUBManifestItem] = [:]
        let itemNodes = (try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) as? [XMLElement] ?? []
        for item in itemNodes {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue {
                hrefByID[id] = href
                let mediaType = item.attribute(forName: "media-type")?.stringValue ?? ""
                mediaTypeByID[id] = mediaType
                let rawProperties = item.attribute(forName: "properties")?.stringValue ?? ""
                let properties = Set(rawProperties.split(whereSeparator: \.isWhitespace).map(String.init))
                manifest[id] = EPUBManifestItem(
                    id: id, href: href, mediaType: mediaType, properties: properties,
                    url: Self.resolve(href, relativeTo: rootFolder))
            }
        }

        let version = (try opf.nodes(forXPath: "/*[local-name()='package']/@version")).first?.stringValue
        let navItem = manifest.values.first(where: { $0.properties.contains("nav") })
        let navigationURL = navItem?.url

        var coverURL: URL?
        let coverMeta = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='meta'][@name='cover']")) as? [XMLElement]
        if let coverID = coverMeta?.first?.attribute(forName: "content")?.stringValue,
            let coverHref = hrefByID[coverID] {
            let decoded = coverHref.removingPercentEncoding ?? coverHref
            let fileURL = URL(fileURLWithPath: decoded, relativeTo: rootFolder).standardizedFileURL
            if FileManager.default.fileExists(atPath: fileURL.path) { coverURL = fileURL }
        }
        if coverURL == nil {
            for (id, href) in hrefByID {
                if href.lowercased().contains("cover"), let mt = mediaTypeByID[id], mt.hasPrefix("image/") {
                    let decoded = href.removingPercentEncoding ?? href
                    let fileURL = URL(fileURLWithPath: decoded, relativeTo: rootFolder).standardizedFileURL
                    if FileManager.default.fileExists(atPath: fileURL.path) { coverURL = fileURL; break }
                }
            }
        }

        var spineItems: [EPUBSpineItem] = []
        let spineNodes = (try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) as? [XMLElement] ?? []
        for node in spineNodes {
            if let ref = node.attribute(forName: "idref")?.stringValue, let href = hrefByID[ref] {
                let url = Self.resolve(href, relativeTo: rootFolder)
                if ["xhtml", "html", "htm"].contains(url.pathExtension.lowercased()) {
                    spineItems.append(EPUBSpineItem(manifestID: ref, url: url, isLinear: node.attribute(forName: "linear")?.stringValue?.lowercased() != "no"))
                }
            }
        }

        let spineURLs = spineItems.map(\.url)

        guard !spineURLs.isEmpty else { throw EPUBParseError.malformed }
        let landmarks = navigationURL.map { Self.parseLandmarks(at: $0) } ?? []
        return EPUBPackage(
            rootFolder: rootFolder, spineURLs: spineURLs, title: bookTitle, author: bookAuthor,
            coverURL: coverURL, manifest: manifest, spine: spineItems, version: version,
            navigationURL: navigationURL, landmarks: landmarks, metadata: metadata)
    }

    private static func resolve(_ href: String, relativeTo base: URL) -> URL {
        let components = URLComponents(string: href)
        let path = (components?.percentEncodedPath.removingPercentEncoding ?? components?.path ?? href).removingPercentEncoding ?? href
        let file = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        guard var resolved = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        resolved.query = components?.query
        resolved.fragment = components?.fragment
        return resolved.url ?? file
    }

    private static func parseLandmarks(at url: URL) -> [EPUBLandmark] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        guard let navRegex = try? NSRegularExpression(pattern: #"(?is)<nav\b([^>]*)>(.*?)</nav\s*>"#),
              let linkRegex = try? NSRegularExpression(pattern: #"(?is)<a\b([^>]*)>(.*?)</a\s*>"#),
              let attributeRegex = try? NSRegularExpression(pattern: #"(?i)([\w:-]+)\s*=\s*([\"'])(.*?)\2"#) else { return [] }
        func attributes(_ source: String, range: NSRange) -> [String: String] {
            guard let range = Range(range, in: source) else { return [:] }
            let text = String(source[range])
            let fullRange = NSRange(text.startIndex..., in: text)
            return Dictionary(attributeRegex.matches(in: text, range: fullRange).compactMap { match in
                guard let keyRange = Range(match.range(at: 1), in: text), let valueRange = Range(match.range(at: 3), in: text) else { return nil }
                return (String(text[keyRange]).lowercased(), String(text[valueRange]))
            }, uniquingKeysWith: { first, _ in first })
        }
        var landmarks: [EPUBLandmark] = []
        for navMatch in navRegex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let navAttrs = attributes(source, range: navMatch.range(at: 1))
            guard navAttrs["epub:type"]?.split(whereSeparator: \.isWhitespace).contains("landmarks") == true,
                  let bodyRange = Range(navMatch.range(at: 2), in: source) else { continue }
            let body = String(source[bodyRange])
            for linkMatch in linkRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let linkAttrs = attributes(body, range: linkMatch.range(at: 1))
                guard let type = linkAttrs["epub:type"], let href = linkAttrs["href"],
                      let titleRange = Range(linkMatch.range(at: 2), in: body) else { continue }
                let title = String(body[titleRange])
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                for semantic in type.split(whereSeparator: \.isWhitespace) {
                    landmarks.append(EPUBLandmark(type: semantic.lowercased(), title: title, url: resolve(href, relativeTo: url.deletingLastPathComponent())))
                }
            }
        }
        return landmarks
    }

    // MARK: - HTML building

    /// `scrollRestoreJS` is baked in as an inline <script> right after readerJS
    /// (which defines honeycrispNavigateToOffset/honeycrispNavigateToChapterFraction),
    /// so it runs synchronously during HTML parse, before WKWebView's first paint —
    /// same reasoning as RestorePosition.bootstrapJS in buildPageHTML. Pass an
    /// empty string when there's nothing to restore (e.g. first-ever open of a
    /// book, at the top by default). See ReaderViewController.scrollRestoreBootstrapJS.
    func buildScrollHTML(
        from pkg: EPUBPackage, cosmetics: ReaderCosmeticSettings,
        scrollRestoreJS: String = "",
        options: ChapterRenderOptions = .plain,
        hideImages: Bool = false,
        skin: ReaderSkin? = nil
    ) throws -> String {
        var body = ""
        let base = pkg.rootFolder
        for i in pkg.spineURLs.indices {
            let extracted = try Self.extractedChapterBody(from: pkg, index: i, base: base, options: options)
            let cut = options.fanficPreface && options.plan?.isHidden(i) == true
            body += "\n<section class=\"ql-chapter\(cut ? " hc-cut\" hidden aria-hidden=\"true" : "")\" id=\"chapter-\(i)\" data-chapter-index=\"\(i)\">\n"
                 + extracted
                 + "\n</section>\n"
        }

        let identity = BookIdentity.detect(pkg)
        let skinBody = skin.map { SkinTemplate.render($0.template, body: body, title: pkg.title, author: pkg.author,
                                                       sourceURL: identity.sourceURL, siteLabel: identity.site?.label,
                                                       date: pkg.metadata["date"]?.first ?? pkg.metadata["issued"]?.first) } ?? body
        let overrideCSS = Self.readerOverrideCSS(cosmetics, skin: skin)
        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style id="honeycrisp-vars">\(Self.readerVarsCSS(cosmetics))</style>
            <style>\(Self.readerCSS)\n\(skin?.css ?? "")\n\(Self.skinCanvasCSS(skin))\n\(overrideCSS)\n\(Self.prefaceCSS)\n\(SourceProfile.forGenerator(identity.generator)?.css ?? "")</style>
            <style>\(Self.imageVisibilityCSS(hideImages: hideImages))</style>
        </head>
        <body>
        <div id="content">\(skinBody)</div>
        <script>window._qlPaginated = false;</script>
        <script>\(Self.readerJS)</script>
        <script>\(scrollRestoreJS)</script>
        </body>
        </html>
        """
    }

    /// Paginated-mode counterpart to buildScrollHTML: one spine item's HTML, with
    /// the column layout CSS baked in up front (never injected after load via
    /// evaluateJavaScript — that's what avoids an unstyled flash before
    /// repagination). PaginationJS and the RestorePosition.bootstrapJS restore
    /// call are baked in the same way, as an inline <script> at the end of
    /// <body>, so the requested column is already on screen for the first
    /// paint — see RestorePosition.bootstrapJS. Uses the same
    /// extractedChapterBody helper as buildScrollHTML, so formatting behaviour
    /// can't drift between the two rendering modes.
    // swiftlint:disable:next function_parameter_count
    func buildPageHTML(
        from pkg: EPUBPackage,
        spineIndex: Int,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        colsPerScreen: ColsPerScreen,
        cosmetics: ReaderCosmeticSettings,
        restorePosition: RestorePosition,
        maxWidth: CGFloat = 700,
        paddingH: CGFloat = 24,
        paddingV: CGFloat = 24,
        options: ChapterRenderOptions = .plain,
        hideImages: Bool = false,
        skin: ReaderSkin? = nil
    ) throws -> String {
        let base = pkg.rootFolder
        let extracted = try Self.extractedChapterBody(from: pkg, index: spineIndex, base: base, options: options)
        let cut = options.fanficPreface && options.plan?.isHidden(spineIndex) == true
        let body = "\n<section class=\"ql-chapter\(cut ? " hc-cut\" hidden aria-hidden=\"true" : "")\" id=\"chapter-\(spineIndex)\" data-chapter-index=\"\(spineIndex)\">\n"
            + extracted
            + "\n</section>\n"

        let columnCSS = Self.paginatedColumnCSS(
            viewportWidth: viewportWidth, viewportHeight: viewportHeight, colsPerScreen: colsPerScreen,
            marginH: paddingH, marginV: paddingV, maxWidth: maxWidth
        )

        // PaginationJS + qlSetup + the restore call run synchronously here,
        // inline, as the last thing parsed in <body> — before WKWebView gets
        // an opportunity to paint. That's what makes the restore column the
        // very first thing rendered instead of a Swift-driven post-load
        // scroll (which always races an already-painted column 0). See
        // RestorePosition.bootstrapJS and PaginationEngine.applyLayout, which
        // now only reads back the result of this script, it doesn't scroll.
        let paginationBootstrap = """
        <script>
        \(PaginationJS.script)
        window.qlSetup(\(colsPerScreen.rawValue));
        \(restorePosition.bootstrapJS)
        </script>
        """

        let identity = BookIdentity.detect(pkg)
        let skinBody = skin.map { SkinTemplate.render($0.template, body: body, title: pkg.title, author: pkg.author,
                                                       sourceURL: identity.sourceURL, siteLabel: identity.site?.label,
                                                       date: pkg.metadata["date"]?.first ?? pkg.metadata["issued"]?.first) } ?? body
        let overrideCSS = Self.readerOverrideCSS(cosmetics, skin: skin)
        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style id="honeycrisp-vars">\(Self.readerVarsCSS(cosmetics))</style>
            <style>\(Self.readerCSS)\n\(skin?.css ?? "")\n\(Self.skinCanvasCSS(skin))\n\(overrideCSS)\n\(Self.prefaceCSS)\n\(SourceProfile.forGenerator(identity.generator)?.css ?? "")</style>
            <style>\(columnCSS)</style>
            <style>\(Self.imageVisibilityCSS(hideImages: hideImages))</style>
        </head>
        <body>
        <div id="content">\(skinBody)</div>
        <script>window._qlPaginated = true;</script>
        <script>\(Self.readerJS)</script>
        \(paginationBootstrap)
        </body>
        </html>
        """
    }

    private static func imageVisibilityCSS(hideImages: Bool) -> String {
        guard hideImages else { return "" }
        return "img, picture, svg image { display: none !important; }"
    }

    /// Horizontal CSS multi-column layout, ported from Ambrosia's
    /// ReaderPreferences.paginatedColumnCSS. Column geometry math and comments kept
    /// as-is — these are empirical WebKit-version-specific fixes, not style
    /// choices. marginH/marginV/maxWidth now come from SettingsManager's
    /// paddingH/paddingV/maxWidth, read by the caller (ReaderViewController.
    /// loadSpineItem) and passed through buildPageHTML — see the appearance-
    /// settings merge pass.
    // swiftlint:disable:next function_body_length function_parameter_count
    private static func paginatedColumnCSS(
        viewportWidth: CGFloat, viewportHeight: CGFloat, colsPerScreen: ColsPerScreen,
        marginH: CGFloat, marginV: CGFloat, maxWidth: CGFloat
    ) -> String {
        let cols = colsPerScreen.rawValue

        let vw = Int(viewportWidth.rounded())
        let vh = Int(viewportHeight.rounded())
        let marginHInt = Int(marginH.rounded())

        // colWidth/colGap divide (vw - 2*marginH) — html's content box after its own
        // padding is subtracted — not vw directly. See ReaderPreferences.paginatedColumnCSS
        // in Ambrosia for the full column-fragmentation-vs-container-padding rationale;
        // dividing vw itself here would double-subtract the margin.
        let availableWidth = vw - 2 * marginHInt

        var colGap = max(1, Int((marginH * 2).rounded()))
        let colWidth: Int
        if cols <= 1 {
            colWidth = availableWidth
        } else {
            let raw = availableWidth + colGap
            let overhang = raw % cols
            if overhang != 0 { colGap += cols - overhang }
            colWidth = (availableWidth + colGap) / cols - colGap
        }

        let capSingleColumn = cols <= 1 && maxWidth < CGFloat(availableWidth)
        let bodyWidthCSS = capSingleColumn
            ? "max-width: \(Int(maxWidth))px !important; margin: 0 auto !important;"
            : "max-width: none !important; margin: 0 !important;"

        return """
        /* === Honeycrisp paginated layout === */
        html {
            /* :root is the column container and the scroll container.
               Horizontal margin lives here (container-level padding — applies
               once, at the true first/last column edge only). */
            width: \(vw)px !important;
            height: \(vh)px !important;
            max-width: \(vw)px !important;
            max-height: \(vh)px !important;
            min-width: \(vw)px !important;
            min-height: \(vh)px !important;
            padding-left: \(marginHInt)px !important;
            padding-right: \(marginHInt)px !important;
            padding-top: \(Int(marginV))px !important;
            padding-bottom: \(Int(marginV))px !important;
            column-width: \(colWidth)px !important;
            column-gap: \(colGap)px !important;
            column-fill: auto !important;
            overflow-x: scroll !important;
            overflow-y: hidden !important;
            scrollbar-width: none !important;
            box-sizing: border-box !important;
        }
        html::-webkit-scrollbar { display: none !important; }
        body {
            /* body must NOT be the column container and must NOT carry padding on
               either axis — its own max-width/margin (bodyWidthCSS) only
               crops/centers the rendered text within each already-sized column. */
            width: 100% !important;
            \(bodyWidthCSS)
            height: auto !important;
            overflow: visible !important;
            box-sizing: border-box !important;
        }
        /* Prevent the first element from creating a blank leading column */
        body > *:first-child,
        body > div:first-child > *:first-child {
            break-before: avoid !important;
        }
        /* Long unbreakable inline runs (AO3 tag lists, dl/dd blocks, tables) can
           force a column wider than column-width requests, throwing off every
           column boundary after it (JS assumes a uniform pitch). Force wrapping
           everywhere so no element can be wider than its column. */
        * {
            max-width: 100% !important;
            overflow-wrap: break-word !important;
            word-break: break-word !important;
        }
        """
    }

    /// Extracts and prepares the `<body>` content of a single spine item: strips the
    /// surrounding `<body>` tag, removes active content (`<style>`, `<script>`, `on*` attributes,
    /// script-scheme URLs), applies AO3 formatting / paragraph-indent stripping /
    /// preface-heading stripping as requested, then rewrites resource URLs to absolute
    /// file URLs. Internal (not private) so tests can call it directly. Shared by `buildScrollHTML`
    /// (all spine items, merged) and, in a future
    /// paginated-mode HTML builder, a single spine item at a time — kept as one code path
    /// so the two rendering modes can't drift apart on formatting behaviour.
    static func extractedChapterBody(
        from pkg: EPUBPackage,
        index: Int,
        base: URL,
        options: ChapterRenderOptions
    ) throws -> String {
        let url = pkg.spineURLs[index]
        let data = try Data(contentsOf: url)
        let src = String(data: data, encoding: .utf8) ?? (String(data: data, encoding: .isoLatin1) ?? "")
        var extracted = Self.stripInlineThemeDeclarations(Self.stripActiveContent(Self.extractBody(html: src)))
        extracted = SourceProfile.tagFanficSpacerParagraphs(in: extracted, generator: BookIdentity.detect(pkg).generator)

        if options.fanficPreface, let plan = options.plan, let meta = options.meta,
            plan.roles.indices.contains(index)
        {
            switch plan.roles[index] {
            case .primaryPreface:
                return FanficPrefaceRenderer.html(data: meta, includeTitleBlock: options.includeTitleBlock)
            case .cut:
                return ""
            case .chapter:
                break
            case .backMatter:
                extracted = Self.stripAfterwordHeading(in: extracted)
            }
        }

        if options.removeParagraphIndents {
            extracted = Self.stripLeadingIndentWhitespace(extracted)
        }

        // AO3 EPUBs emit a redundant "Preface" heading on the first spine item;
        // the spine item is the preface by definition once rendered here.
        if index == 0 && !options.fanficPreface {
            extracted = Self.stripPrefaceHeading(extracted)
        }

        return Self.rewriteResourceURLs(in: extracted, base: base)
    }

    private static func stripAfterwordHeading(in html: String) -> String {
        let pattern = #"(?is)(<[^>]+id=[\"']afterword[\"'][^>]*>)(.*?)(<h[1-6][^>]*class=[\"'][^\"']*toc-heading[^\"']*[\"'][^>]*>.*?</h[1-6]>)"#
        return html.replacingOccurrences(of: pattern, with: "$1$2", options: .regularExpression)
    }

    private static func stripInlineThemeDeclarations(_ html: String) -> String {
        let pattern = #"(?i)\sstyle\s*=\s*([\"'])(.*?)\1"#
        return html.replacingOccurrences(of: pattern) { match, matched in
            let ns = matched as NSString
            let declarationRange = match.range(at: 2)
            guard declarationRange.location != NSNotFound else { return matched }
            let source = ns.substring(with: declarationRange)
            let kept = source.split(separator: ";", omittingEmptySubsequences: false).compactMap { item -> String? in
                let declaration = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colon = declaration.firstIndex(of: ":") else { return declaration.isEmpty ? nil : declaration }
                let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return ["color", "background", "background-color", "font-family"].contains(property) ? nil : declaration
            }
            guard !kept.isEmpty else { return "" }
            let quote = ns.substring(with: match.range(at: 1))
            return " style=\(quote)\(kept.joined(separator: ";"))\(quote)"
        }
    }

    // MARK: - Active content removal

    /// Removes markup that can run code or restyle the page from a spine item's body: `<style>` and
    /// `<script>` elements (with content, including Wikisource-style `<style><![CDATA[...]]></style>`),
    /// `on*` event-handler attributes, and `href`/`src`-style attributes whose value is a script or HTML
    /// data scheme (neutralized to `#`). Ordinary links and images are untouched. Book content is
    /// untrusted; this runs before every other transformation.
    static func stripActiveContent(_ html: String) -> String {
        var out = html
        // Self-closing forms first, so the paired-element pattern cannot swallow content after `<script src=x/>`.
        out = out.replacingOccurrences(of: #"(?i)<(?:style|script)\b[^>]*/>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?is)<(style|script)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        // Unclosed or stray tags left behind.
        out = out.replacingOccurrences(of: #"(?i)</?(?:style|script)\b[^>]*>"#, with: "", options: .regularExpression)

        // The tag prefix consumes quoted values as units, so `title="a onclick=1"` is not mistaken for a handler.
        let handler = #"(?i)(<[A-Za-z](?:"[^"]*"|'[^']*'|[^<>"'])*?)[\s/]+on[A-Za-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'<>]+)"#
        var passes = 0
        var previous = ""
        repeat {
            previous = out
            out = out.replacingOccurrences(of: handler, with: "$1", options: .regularExpression)
            passes += 1
        } while out != previous && passes < 32

        return neutralizeScriptURLs(in: out)
    }

    private static func neutralizeScriptURLs(in html: String) -> String {
        let pattern = #"\b(?:href|src|xlink:href|action|formaction)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        return html.replacingOccurrences(of: pattern) { match, matched in
            let ns = matched as NSString
            var valueRange = match.range(at: 1)
            if valueRange.location == NSNotFound { valueRange = match.range(at: 2) }
            guard valueRange.location != NSNotFound else { return matched }
            let local = NSRange(location: valueRange.location - match.range.location, length: valueRange.length)
            guard isScriptScheme(ns.substring(with: local)) else { return matched }
            return ns.replacingCharacters(in: local, with: "#")
        }
    }

    /// True when a URL attribute value is `javascript:`, `vbscript:` or `data:text/html` after the same
    /// normalization browsers apply (entity decoding, dropped whitespace and control characters, case).
    private static func isScriptScheme(_ value: String) -> Bool {
        var text = value.replacingOccurrences(of: "&tab;", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&newline;", with: "", options: .caseInsensitive)
        text = decodeHTMLEntities(text)
        let dropped = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !dropped.contains(scalar) { scalars.append(scalar) }
        let normalized = String(scalars).lowercased()
        return normalized.hasPrefix("javascript:") || normalized.hasPrefix("vbscript:") || normalized.hasPrefix("data:text/html")
    }

    /// Strips leading space/tab runs immediately inside paragraph-like elements — the
    /// literal-whitespace equivalent of a `text-indent: 0` CSS override, for books that
    /// fake first-line indentation with actual whitespace characters rather than CSS.
    /// Scoped to `p, div, li` plus headings/blockquote/table cells, since those are
    /// equally plausible homes for a converted-from-plaintext indent. Deliberately does
    /// not touch `&nbsp;`-based fake indents — a different, separate pattern.
    private static func stripLeadingIndentWhitespace(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"(?i)(<(?:p|div|li|h[1-6]|blockquote|td|th)[^>]*>)[ \t]+"#,
            with: "$1", options: .regularExpression)
    }

    /// Strips a redundant "Preface" heading (AO3 uses <h2 class="toc-heading"> in
    /// practice, but the level varies; match h1-h6 with a backreference so only the
    /// matching close tag is eaten). Only ever applied to spine index 0.
    private static func stripPrefaceHeading(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<(h[1-6])[^>]*>\s*[Pp]reface\s*</\1>"#,
            with: "", options: .regularExpression)
    }

    private static func extractBody(html: String) -> String {
        guard let start = html.range(of: "<body", options: .caseInsensitive),
              let gt = html[start.lowerBound...].firstIndex(of: ">"),
              let end = html.range(of: "</body>", options: .caseInsensitive)
        else { return html }
        return String(html[html.index(after: gt)..<end.lowerBound])
    }

    private static func rewriteResourceURLs(in html: String, base: URL) -> String {
        let patterns = ["src=\"([^\"]+)\"", "href=\"([^\"]+)\""]
        var out = html
        for candidate in patterns {
            out = out.replacingOccurrences(of: candidate) { match, matched in
                let whole = match.range
                let cap = match.range(at: 1)
                let capInMatch = NSRange(location: cap.location - whole.location, length: cap.length)
                let nsMatched = matched as NSString
                let val = nsMatched.substring(with: capInMatch)

                if val.hasPrefix("http") || val.hasPrefix("file:") || val.hasPrefix("data:") ||
                   val.hasPrefix("#") || val.hasPrefix("mailto:") || val.hasPrefix("javascript:") {
                    return matched
                }

                let local = val.hasPrefix("/") ? String(val.dropFirst()) : val
                let abs = URL(fileURLWithPath: local, relativeTo: base).standardizedFileURL.absoluteString
                return nsMatched.replacingCharacters(in: capInMatch, with: abs)
            }
        }
        return out
    }

    // MARK: - JS injected into reader page (progress reporting + TOC navigation)

    static let readerJS = """
    // ── Search ────────────────────────────────────────────────────────────────────

    var _hits = [];
    var _hitIdx = -1;
    var _nativeSearchTerm = null;

    /**
     * Highlight all occurrences of `term` across all chapter sections.
     * Returns the total hit count (read by Swift via evaluateJavaScript).
     */
    window.searchText = function(term) {
      var clearNativeSelection = _nativeSearchTerm !== null;
      // 1. Remove previous highlights
      document.querySelectorAll('mark.ql-hit').forEach(function(m) {
        var parent = m.parentNode;
        parent.replaceChild(document.createTextNode(m.textContent), m);
        parent.normalize();
      });
      _hits = [];
      _hitIdx = -1;
      _nativeSearchTerm = null;

      if (!term || term.length < 1) {
        if (clearNativeSelection) window.getSelection().removeAllRanges();
        return 0;
      }

      if (window._qlPaginated) {
        _nativeSearchTerm = term;
        var escaped = term.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
        var matcher = new RegExp(escaped, 'gi');
        var count = 0;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        var textNode;
        while ((textNode = walker.nextNode()) !== null) {
          var matches = textNode.textContent.match(matcher);
          if (matches) count += matches.length;
        }
        window.getSelection().removeAllRanges();
        window.find(term, false, false, true, false, false, false);
        return count;
      }

      // 2. Walk all text nodes and wrap matches
      var escapedTerm = term.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      var re = new RegExp(escapedTerm, 'gi');

      function walkNode(node) {
        if (node.nodeType === Node.TEXT_NODE) {
          var text = node.textContent;
          if (!re.test(text)) return;
          re.lastIndex = 0;

          var frag = document.createDocumentFragment();
          var last = 0;
          var m;
          while ((m = re.exec(text)) !== null) {
            frag.appendChild(document.createTextNode(text.slice(last, m.index)));
            var mark = document.createElement('mark');
            mark.className = 'ql-hit';
            mark.textContent = m[0];
            frag.appendChild(mark);
            _hits.push(mark);
            last = re.lastIndex;
          }
          frag.appendChild(document.createTextNode(text.slice(last)));
          node.parentNode.replaceChild(frag, node);
        } else if (
          node.nodeType === Node.ELEMENT_NODE &&
          node.tagName !== 'SCRIPT' &&
          node.tagName !== 'STYLE' &&
          node.tagName !== 'MARK'
        ) {
          // Clone childNodes list to avoid live-collection mutation issues
          Array.from(node.childNodes).forEach(walkNode);
        }
      }

      walkNode(document.body);

      // 3. Scroll first hit into view and mark it active
      if (_hits.length > 0) {
        _hitIdx = 0;
        _activateHit(_hitIdx);
      }

      return _hits.length;
    };

    /**
     * Advance (+1) or retreat (-1) through search results.
     */
    window.nextSearchResult = function(direction) {
      if (_nativeSearchTerm) {
        window.find(_nativeSearchTerm, false, direction < 0, true, false, false, false);
        return;
      }
      if (_hits.length === 0) return;
      _hits[_hitIdx].classList.remove('ql-active');
      _hitIdx = (_hitIdx + direction + _hits.length) % _hits.length;
      _activateHit(_hitIdx);
    };

    function _activateHit(idx) {
      var hit = _hits[idx];
      hit.classList.add('ql-active');
      hit.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }

    // ── Chapter navigation ────────────────────────────────────────────────────────

    window.navigateToChapter = function(idx) {
      var sections = document.querySelectorAll('.ql-chapter');
      if (window._qlPaginated) {
        if (idx >= 0 && idx < sections.length) sections[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
      } else if (idx >= 0 && idx < sections.length) {
        sections[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    };

    window.navigateToFragment = function(id) {
      var el = document.getElementById(id);
      if (!el) {
        var named = document.getElementsByName(id);
        el = named.length ? named[0] : null;
      }
      if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    };

    window.navigateToChapterEnd = function(idx) {
      var section = document.getElementById('chapter-' + idx);
      if (section) section.scrollIntoView({ behavior: 'smooth', block: 'end' });
    };

    window.honeycrispCurrentSpeechText = function(spineIndex) {
      var section = document.getElementById('chapter-' + spineIndex);
      if (!section) return '';
      var selection = window.getSelection();
      if (selection && !selection.isCollapsed && selection.toString().trim()) return selection.toString();
      var x = Math.round(window.innerWidth / 2), y = Math.round(window.innerHeight / 3);
      var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      var target = range && section.contains(range.startContainer) ? range.startContainer : null;
      var offset = target ? range.startOffset : 0, started = !target, parts = [];
      var walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT, null), node;
      while ((node = walker.nextNode()) !== null) {
        if (!started && node === target) started = true;
        if (started) parts.push(node.textContent.slice(node === target ? offset : 0));
      }
      return parts.join(' ').replace(/\\s+/g, ' ').trim();
    };

    ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(function(type) {
      window.addEventListener(type, function() {
        if (window.honeycrispAutoScrollFrame) {
          cancelAnimationFrame(window.honeycrispAutoScrollFrame);
          window.honeycrispAutoScrollFrame = null;
        }
      }, { passive: true });
    });

    // ── Reading progress ──────────────────────────────────────────────────────────

    function reportProgress() {
      // Paginated mode clips document height to the viewport and scrolls
      // horizontally (see paginatedColumnCSS: html { height: <vh>px;
      // overflow-y: hidden }), so scrollY stays ~0 and scrollHeight stays
      // ~innerHeight regardless of position -- this math would report ~100%
      // on every single page turn. Paginated progress is instead computed
      // Swift-side from spine index/column (see ReaderViewController.
      // reportPaginatedProgress) and window._qlPaginated (set by
      // buildPageHTML, absent/false in buildScrollHTML) is what tells this
      // shared function to defer to that instead of posting its own bogus
      // value over the same progressHandler channel.
      if (window._qlPaginated) return;
      var scrolled = window.scrollY + window.innerHeight;
      var total    = document.documentElement.scrollHeight;
      var pct      = total > 0 ? Math.round((scrolled / total) * 100) : 0;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.progressHandler) {
        window.webkit.messageHandlers.progressHandler.postMessage(Math.min(100, pct));
      }
    }

    // ── Reading position (exact character offset) ─────────────────────────────────
    //
    // Offset contract: UTF-16 code units, counted via a TreeWalker(SHOW_TEXT) over
    // document.body. honeycrispCurrentCharacterOffset (save side) and
    // honeycrispNavigateToOffset (restore side) both walk document.body with the
    // exact same TreeWalker construction, so they can't drift out of sync with
    // each other — one contract, read on one side and written on the other.

    var HONEYCRISP_POSITION_REFERENCE_Y = Math.round(window.innerHeight / 3);

    window.honeycrispCurrentCharacterOffset = function() {
      var x = Math.round(window.innerWidth / 2);
      var y = HONEYCRISP_POSITION_REFERENCE_Y;
      var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      if (!range || !range.startContainer || range.startContainer.nodeType !== Node.TEXT_NODE) {
        return -1;
      }
      var target = range.startContainer;
      var localOffset = range.startOffset;
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var count = 0, node;
      while ((node = walker.nextNode()) !== null) {
        if (node === target) return count + localOffset;
        count += node.length;
      }
      return count;
    };

    window.honeycrispCurrentChapterCharacterOffset = function() {
      var sections = document.querySelectorAll('.ql-chapter');
      var section = sections[window.honeycrispPageInfo().spineIndex];
      if (!section) return -1;
      var x = Math.round(window.innerWidth / 2);
      var y = HONEYCRISP_POSITION_REFERENCE_Y;
      var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      var target = range && range.startContainer && range.startContainer.nodeType === Node.TEXT_NODE && section.contains(range.startContainer) ? range.startContainer : null;
      if (!target) return -1;
      var localOffset = range.startOffset;
      var walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT, null);
      var count = 0, node;
      while ((node = walker.nextNode()) !== null) {
        if (node === target) return count + localOffset;
        count += node.length;
      }
      return -1;
    };

    // Character range currently on screen, as [start, end] in the same offset space
    // as honeycrispCurrentCharacterOffset (paginated: whole body) or
    // honeycrispCurrentChapterCharacterOffset (scroll: the given chapter section).
    // A bookmark whose offset falls inside this range belongs to the visible page,
    // wherever on the page it was dropped. Returns null when nothing is measurable.
    window.honeycrispVisibleCharacterRange = function(scrollMode, spineIndex) {
      var root = document.body;
      if (scrollMode) {
        root = document.getElementById('chapter-' + spineIndex);
        if (!root) return null;
      }
      var viewW = window.innerWidth, viewH = window.innerHeight;
      // -1: before the viewport, 1: after it, 0: touches it, null: unmeasurable.
      function side(rect) {
        if (!rect || (rect.width === 0 && rect.height === 0)) return null;
        if (scrollMode) return rect.bottom <= 0 ? -1 : (rect.top >= viewH ? 1 : 0);
        return rect.right <= 0 ? -1 : (rect.left >= viewW ? 1 : 0);
      }
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var nodes = [], starts = [], count = 0, node;
      while ((node = walker.nextNode()) !== null) {
        if (node.data.trim().length > 0) { nodes.push(node); starts.push(count); }
        count += node.length;
      }
      if (!nodes.length) return null;
      var range = document.createRange();
      // First index in [0, n) where pred is true. pred is false then true across
      // the range (reading order is monotonic on screen); null means unmeasurable
      // and is skipped forward.
      function lowerBound(n, pred) {
        var lo = 0, hi = n;
        while (lo < hi) {
          var mid = (lo + hi) >> 1, j = mid, p = pred(j);
          while (p === null && j + 1 < hi) { j += 1; p = pred(j); }
          if (p === null) { hi = mid; continue; }
          if (p) hi = j; else lo = j + 1;
        }
        return lo;
      }
      function nodeSide(i) {
        range.selectNodeContents(nodes[i]);
        return side(range.getBoundingClientRect());
      }
      function charSide(n, k) {
        range.setStart(n, k);
        range.setEnd(n, k);
        return side(range.getBoundingClientRect());
      }
      var firstNode = lowerBound(nodes.length, function(i) {
        var s = nodeSide(i); return s === null ? null : s >= 0;
      });
      var afterNode = lowerBound(nodes.length, function(i) {
        var s = nodeSide(i); return s === null ? null : s > 0;
      });
      if (firstNode >= afterNode) return null;
      var lastNode = afterNode - 1;
      // A long paragraph is one text node and can span several pages, so refine
      // the two edge nodes down to the character that actually starts/ends the page.
      var first = nodes[firstNode], last = nodes[lastNode];
      var startK = lowerBound(first.length + 1, function(k) {
        var s = charSide(first, k); return s === null ? null : s >= 0;
      });
      var endK = lowerBound(last.length + 1, function(k) {
        var s = charSide(last, k); return s === null ? null : s > 0;
      });
      var start = starts[firstNode] + Math.min(startK, first.length);
      var end = starts[lastNode] + Math.min(endK, last.length);
      return [start, Math.max(start, end)];
    };

    window.honeycrispNavigateToChapterOffset = function(spineIndex, targetOffset) {
      var section = document.getElementById('chapter-' + spineIndex);
      if (!section) return;
      var walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT, null);
      var count = 0, node, lastNode = null;
      while ((node = walker.nextNode()) !== null) {
        lastNode = node;
        if (targetOffset <= count + node.length) {
          var range = document.createRange();
          range.setStart(node, Math.max(0, Math.min(node.length, targetOffset - count)));
          range.setEnd(range.startContainer, range.startOffset);
          var rect = range.getBoundingClientRect();
          window.scrollTo(0, Math.max(0, window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y));
          return;
        }
        count += node.length;
      }
      if (lastNode) {
        var end = document.createRange();
        end.selectNodeContents(lastNode);
        end.collapse(false);
        var rect = end.getBoundingClientRect();
        window.scrollTo(0, Math.max(0, window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y));
      }
    };

    // Seeks scroll mode to a given spine item at a given fraction (0.0-1.0)
    // through that item's rendered height. Used when toggling from paginated
    // mode back to scroll mode, to hand off the live in-session position
    // (spine index + column fraction) rather than falling back to whatever
    // was last persisted to HistoryEntry, which can be stale if the user
    // toggles modes before the debounced position save has flushed.
    window.honeycrispNavigateToChapterFraction = function(spineIndex, fraction) {
      var section = document.getElementById('chapter-' + spineIndex);
      if (!section) return;
      var rect = section.getBoundingClientRect();
      var top = rect.top + window.scrollY;
      var targetY = top + Math.max(0, Math.min(1, fraction)) * rect.height;
      window.scrollTo(0, Math.max(0, targetY));
    };

    window.honeycrispNavigateToOffset = function(targetOffset) {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var count = 0, node, lastNode = null;
      while ((node = walker.nextNode()) !== null) {
        lastNode = node;
        var nextCount = count + node.length;
        if (targetOffset < nextCount) {
          scrollNodeIntoPosition(node, targetOffset - count);
          return;
        }
        count = nextCount;
      }
      // Offset is at or past the end of the document — land on the last text node.
      if (lastNode) scrollNodeIntoPosition(lastNode, lastNode.length);

      function scrollNodeIntoPosition(node, localOffset) {
        localOffset = Math.max(0, Math.min(node.length, localOffset));
        var range = document.createRange();
        range.setStart(node, localOffset);
        range.setEnd(node, localOffset);
        var rect = range.getBoundingClientRect();
        var targetY = window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y;
        window.scrollTo(0, Math.max(0, targetY));
      }
    };

    function reportPosition() {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.positionHandler) {
        var sections = document.querySelectorAll('.ql-chapter');
        var offset = sections.length > 1
          ? window.honeycrispCurrentChapterCharacterOffset()
          : window.honeycrispCurrentCharacterOffset();
        window.webkit.messageHandlers.positionHandler.postMessage(offset);
      }
    }

    // ── Page count (menu bar display) ──────────────────────────────────────────
    //
    // "Page" here means one window-height of scroll, matching paginated mode's
    // one-column-per-page convention. Scroll mode's document is the whole book
    // merged into one continuous document (see buildScrollHTML), so page and
    // totalPages are computed against the document as a whole -- current
    // scroll position over total scrollable height -- not scoped to whichever
    // chapter section the viewport happens to be in. spineIndex/spineCount
    // (via the same .ql-chapter markers navigateToChapter uses) are reported
    // alongside for callers that want chapter position separately.

    window.honeycrispPageInfo = function() {
      var sections = document.querySelectorAll('.ql-chapter');
      var viewTop  = window.scrollY;
      var winH     = Math.max(1, window.innerHeight);
      var docHeight = Math.max(1, document.documentElement.scrollHeight);
      var idx = 0;

      for (var i = 0; i < sections.length; i++) {
        if (sections[i].classList.contains('hc-cut')) continue;
        var rect = sections[i].getBoundingClientRect();
        var top  = rect.top + window.scrollY;
        if (top <= viewTop + 1) {
          idx = i;
        }
      }

      var page        = Math.max(1, Math.round(viewTop / winH) + 1);
      var totalPages  = Math.max(1, Math.ceil(docHeight / winH));

      return JSON.stringify({
        page: Math.min(page, totalPages),
        totalPages: totalPages,
        spineIndex: idx,
        spineCount: Math.max(1, sections.length)
      });
    };

    window.reportPageInfo = function() {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pageInfoHandler) {
        window.webkit.messageHandlers.pageInfoHandler.postMessage(window.honeycrispPageInfo());
      }
    };

    // reportPageInfo() is a pure in-memory read (no disk I/O), so it's driven
    // by its own rAF-coalesced call rather than the 500ms debounce below --
    // that debounce exists to throttle reportProgress()/reportPosition()'s
    // disk writes, and folding reportPageInfo() into it left the toolbar page
    // counter stale until 500ms after scrolling stopped.
    var pageInfoRAFPending = false;
    window.addEventListener('scroll', function() {
      if (!pageInfoRAFPending) {
        pageInfoRAFPending = true;
        requestAnimationFrame(function() {
          pageInfoRAFPending = false;
          reportPageInfo();
        });
      }
      clearTimeout(window._progressTimer);
      window._progressTimer = setTimeout(function() {
        reportProgress();
        reportPosition();
      }, 500);
    }, { passive: true });

    // totalPages depends on window.innerHeight, which a scroll event alone
    // doesn't cover -- resizing the window without scrolling left the page
    // counter stale until this listener was added.
    window.addEventListener('resize', function() {
      clearTimeout(window._resizeTimer);
      window._resizeTimer = setTimeout(function() {
        reportPageInfo();
      }, 250);
    }, { passive: true });

    // Page info also needs an immediate read on load (before the first scroll
    // event ever fires), so the menu bar isn't blank until the reader scrolls.
    reportPageInfo();
    """

    // MARK: - CSS

    /// The `:root` CSS custom properties, emitted into their own `<style id="honeycrisp-vars">`
    /// element so `applyCosmeticCSSUpdate` (in ReaderViewController) can replace just this
    /// element's textContent on a settings change, without touching the rest of the stylesheet.
    ///
    /// This is a function of the actual current settings, not a static default —
    /// buildScrollHTML/buildPageHTML bake real values in here at build time (same
    /// treatment paginatedColumnCSS already gets), and applyCosmeticCSSUpdate's
    /// live JS patch calls this exact function too, so there is one definition of
    /// what the vars block contains, not two that can drift apart. Baking real
    /// values in from the start also means there is no longer a static/default
    /// frame to flash before the real ones land -- see ReaderCosmeticSettings.
    static func readerVarsCSS(_ cosmetics: ReaderCosmeticSettings) -> String {
        """
        :root {
            color-scheme: light dark;
            --reader-font-size: \(cosmetics.fontSizePercent)%;
            --reader-font-family: \(cosmetics.fontFamily);
            --reader-bg: \(cosmetics.backgroundCSS);
            --reader-text: \(cosmetics.textCSS);
            --reader-link: \(cosmetics.linkCSS);
            --reader-hit-bg: \(cosmetics.hitBackground);
            --reader-hit-text: \(cosmetics.hitText);
            --reader-hit-active-bg: \(cosmetics.hitActiveBackground);
            --reader-hit-active-text: \(cosmetics.hitActiveText);
            --reader-line-height: \(cosmetics.lineHeight);
            --reader-max-width: \(cosmetics.maxWidth)px;
            --reader-padding-h: \(cosmetics.paddingH)px;
            --reader-padding-v: \(cosmetics.paddingV)px;
            --reader-link-pointer-events: \(cosmetics.allowLinkClicks ? "auto" : "none");
        }
        """
    }

    static func readerOverrideCSS(_ cosmetics: ReaderCosmeticSettings, skin: ReaderSkin?) -> String {
        var rules: [String] = []
        rules.append("html, body { -webkit-text-size-adjust: 100% !important; text-size-adjust: 100% !important; }")
        if !cosmetics.fontFamily.isEmpty {
            rules.append("body, #bodyContainer { font-family: \(cosmetics.fontFamily) !important; }")
            rules.append("h1, h2, h3, h4, h5, h6 { font-family: \(cosmetics.fontFamily) !important; }")
        }
        rules.append("body { font-size: var(--reader-font-size) !important; line-height: var(--reader-line-height) !important; }")
        if skin == nil { rules.append("body { max-width: var(--reader-max-width) !important; }") }
        if !cosmetics.backgroundCSS.isEmpty { rules.append("body, #bodyContainer { background-color: \(cosmetics.backgroundCSS) !important; }") }
        if !cosmetics.textCSS.isEmpty { rules.append("body, #bodyContainer { color: \(cosmetics.textCSS) !important; }") }
        if !cosmetics.linkCSS.isEmpty { rules.append("#bodyContainer a:not(#ao3Preface a) { color: \(cosmetics.linkCSS) !important; }") }
        rules.append("#bodyContainer p, #bodyContainer li, #bodyContainer blockquote, #bodyContainer dd { text-indent: \(cosmetics.paragraphIndent)em !important; margin-bottom: \(cosmetics.paragraphSpacing)em !important; }")
        if cosmetics.justify { rules.append("#bodyContainer p:not([align]):not([class*=center]):not([style*=text-align]) { text-align: justify !important; }") }
        if cosmetics.hyphenate { rules.append("#bodyContainer p, #bodyContainer li { -webkit-hyphens: auto !important; hyphens: auto !important; }") }
        if skin != nil, cosmetics.maxWidth > 0 {
            rules.append("body { max-width: none !important; }")
        }
        return rules.joined(separator: "\n")
    }

    static let readerCSS = """
    /* Search highlight colours */
    mark.ql-hit {
        background: var(--reader-hit-bg);
        color: var(--reader-hit-text);
        border-radius: 2px;
        padding: 0 1px;
    }
    mark.ql-hit.ql-active {
        background: var(--reader-hit-active-bg);
        color: var(--reader-hit-active-text);
        outline: 2px solid var(--reader-hit-text);
    }

    html {
        box-sizing: border-box;
        overflow-x: hidden;
        max-width: 100%;
        font-size: var(--reader-font-size);
        -webkit-text-size-adjust: 100%;
        text-size-adjust: 100%;
    }

    *, *::before, *::after { box-sizing: inherit; }

    body {
        font-family: var(--reader-font-family);
        color: var(--reader-text);
        font-size: 1.1rem;
        line-height: var(--reader-line-height);
        padding: 0;
        margin: 0;
        background: transparent;
        overflow-x: hidden;
        max-width: 100%;
    }

    #content { width: 100%; max-width: var(--reader-max-width); margin: 0 auto; padding: var(--reader-padding-v) var(--reader-padding-h); }
    .ql-chapter { margin: 40px 0; }
    .ql-chapter.hc-cut { display: none !important; }
    .ql-chapter + .ql-chapter {
        border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent);
        padding-top: 40px;
    }

    img, svg, video, iframe { max-width: 100%; height: auto; display: block; margin: 1.2em auto; }

    h1, h2, h3, h4, h5, h6 {
        font-family: var(--reader-font-family);
        line-height: 1.25;
        margin-top: 1.5em;
        margin-bottom: 0.5em;
    }

    blockquote {
        border-inline-start: 3px solid color-mix(in srgb, currentColor 20%, transparent);
        padding-inline-start: 12px;
        margin-inline: 0;
        color: color-mix(in srgb, currentColor 80%, black);
    }

    code, pre {
        font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
        white-space: pre-wrap;
        word-break: break-all;
    }

    a { color: var(--reader-link); pointer-events: var(--reader-link-pointer-events); }

    :where(#bodyContainer *) { font-family: inherit; color: inherit; background-color: transparent; }

    img, svg { color: unset !important; }
    """

    static let prefaceCSS = """
    #ao3Preface, #ao3Preface * { box-sizing: border-box; }
    #ao3Preface { margin: 0 auto 2em; max-width: 54em; font-size: .95em; }
    #ao3Preface .heading { margin: .4em 0; }
    #ao3Preface .byline, #ao3Preface .message { margin: .5em 0 1em; }
    #ao3Preface .tags { display: grid; grid-template-columns: max-content minmax(0,1fr); gap: .25em .8em; }
    #ao3Preface dt { font-weight: 600; }
    #ao3Preface dt.wide { grid-column: 1; }
    #ao3Preface dd.wide { grid-column: 2; }
    #ao3Preface .module { margin: 1.2em 0; }
    #ao3Preface .userstuff { margin: .5em 0; }
    """

    private static func skinCanvasCSS(_ skin: ReaderSkin?) -> String {
        // The resolved reader color already includes skin tokens and user
        // overrides. Use it for the full document canvas so it cannot diverge
        // from the body/content background and expose a hard edge at the window.
        return "html { background-color: var(--reader-bg) !important; }"
    }
}

private extension String {
    func replacingOccurrences(of pattern: String, with transform: (_ match: NSTextCheckingResult, _ matched: String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return self }
        var result = self
        var delta = 0
        let originalNSString = self as NSString
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            let matched = originalNSString.substring(with: match.range)
            let replacement = transform(match, matched)
            let adjustedRange = NSRange(location: match.range.location + delta, length: match.range.length)
            result = (result as NSString).replacingCharacters(in: adjustedRange, with: replacement)
            delta += replacement.count - match.range.length
        }
        return result
    }
}
