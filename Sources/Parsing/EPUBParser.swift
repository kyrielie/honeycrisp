// EPUBParser.swift
// Parses EPUB files into structured content, adapted from the QuickLook plugin

import Foundation
import ZIPFoundation

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

    func searchResults(
        for term: String,
        in package: EPUBPackage,
        limit: Int = 250,
        options: ChapterTransformOptions = .init()
    ) -> [BookSearchResult] {
        ChapterSearch.searchResults(for: term, in: package, limit: limit, options: options)
    }

    func speechText(
        in package: EPUBPackage,
        at index: Int,
        options: ChapterTransformOptions = .init()
    ) -> String? {
        ChapterSearch.speechText(in: package, at: index, options: options)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func parseOPF(at opfURL: URL) throws -> EPUBPackage {
        let rootFolder = opfURL.deletingLastPathComponent()
        let opfData = try Data(contentsOf: opfURL)
        let opf = try XMLDocument(data: opfData)

        let titleNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']")).first as? XMLElement
        let authorNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']")).first as? XMLElement
        let languageNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='language']")).first as? XMLElement
        let publisherNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='publisher']")).first as? XMLElement
        let identifierNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='identifier']")).first as? XMLElement
        let dateNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='date']")).first as? XMLElement
        let descriptionNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='description']")).first as? XMLElement
        let subjectNodes = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='subject']")) as? [XMLElement] ?? []
        let subjects = subjectNodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let bookTitle = titleNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bookAuthor = authorNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let language = Self.sanitizedLanguageTag(languageNode?.stringValue)
        let publisher = publisherNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = identifierNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicationDate = dateNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookDescription = descriptionNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

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
            navigationURL: navigationURL, landmarks: landmarks, language: language,
            publisher: publisher, identifier: identifier, publicationDate: publicationDate,
            bookDescription: bookDescription, subjects: subjects)
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

    static func sanitizedLanguageTag(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
        let letters = CharacterSet.letters
        let digits = CharacterSet.decimalDigits
        func isASCIIAlpha(_ value: Substring) -> Bool {
            value.unicodeScalars.allSatisfy { $0.isASCII && letters.contains($0) }
        }
        func isASCIIAlphanumeric(_ value: Substring) -> Bool {
            value.unicodeScalars.allSatisfy { $0.isASCII && (letters.contains($0) || digits.contains($0)) }
        }
        guard let primary = parts.first, (2...8).contains(primary.count), isASCIIAlpha(primary) else {
            return nil
        }
        guard parts.dropFirst().allSatisfy({
            (1...8).contains($0.count) && isASCIIAlphanumeric($0)
        }) else { return nil }
        return parts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4, isASCIIAlpha(part) {
                return part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }
            if part.count == 2, isASCIIAlpha(part) { return part.uppercased() }
            return part.lowercased()
        }.joined(separator: "-")
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

    // MARK: - CSS

    static func imageVisibilityCSS(hideImages: Bool) -> String {
        ReaderStyles.imageVisibilityCSS(hideImages: hideImages)
    }

    // swiftlint:disable:next function_parameter_count
    static func paginatedColumnCSS(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        colsPerScreen: ColsPerScreen,
        marginH: CGFloat,
        marginV: CGFloat,
        maxWidth: CGFloat
    ) -> String {
        ReaderStyles.paginatedColumnCSS(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            colsPerScreen: colsPerScreen,
            marginH: marginH,
            marginV: marginV,
            maxWidth: maxWidth
        )
    }

    // MARK: - JS injected into reader page (progress reporting + TOC navigation)

    static var readerJS: String {
        ReaderScripts.readerJS
    }

    // MARK: - CSS

    /// Font stack for `code` and `pre` when the theme font does not override them.
    static var monospaceStack: String {
        ReaderStyles.monospaceStack
    }

    static func readerVarsCSS(_ cosmetics: ReaderCosmeticSettings) -> String {
        ReaderStyles.readerVarsCSS(cosmetics)
    }

    static var readerCSS: String {
        ReaderStyles.readerCSS
    }
}
