import Foundation
import SwiftSoup

/// Gate for the flow surface (roadmap M4a). Enabled by default unless explicitly disabled with
/// `HONEYCRISP_FLOW=0` or `HONEYCRISP_LEGACY=1`.
enum FlowSurfaceFlag {
    static let environmentKey = "HONEYCRISP_FLOW"

    static var isEnabled: Bool { isEnabled(environment: ProcessInfo.processInfo.environment) }

    static func isEnabled(environment: [String: String]) -> Bool {
        if environment["HONEYCRISP_LEGACY"] == "1" { return false }
        if environment[environmentKey] == "0" { return false }
        return true
    }
}

/// Builds a unified multi-chapter flow document (FRAMEWORK C5, roadmap M4a).
/// Concatenates rendered chapter bodies into `<section class="hc-chapter" id="hc-r{N}" data-resource="{N}">`,
/// namespaces element IDs as `hc-r{N}-{id}`, rewrites in-book links (`href="#hc-r{target}-{id}"` or `href="#hc-r{target}"`),
/// and resolves resource URLs under the custom scheme (`honeycrisp-epub://book/...`).
enum FlowDocumentBuilder {
    static let defaultScheme = "honeycrisp-epub"

    /// Builds a fast lookup table from standardized chapter file URL to spine resource index.
    static func buildSpineLookup(spineURLs: [URL]) -> [URL: Int] {
        var lookup: [URL: Int] = [:]
        for (index, url) in spineURLs.enumerated() {
            lookup[url.resolvingSymlinksInPath().standardizedFileURL] = index
        }
        return lookup
    }

    /// Namespaces all `id` and anchor `name` attributes inside a chapter body with `hc-r{resource}-`.
    static func namespaceElementIDs(in body: Element, resource: Int) throws {
        for el in try body.select("[id]") {
            let oldId = try el.attr("id")
            guard !oldId.isEmpty else { continue }
            try el.attr("id", "hc-r\(resource)-\(oldId)")
        }
        for el in try body.select("a[name]") {
            let name = try el.attr("name")
            guard !name.isEmpty, !el.hasAttr("id") else { continue }
            try el.attr("id", "hc-r\(resource)-\(name)")
        }
    }

    /// Per-chapter context used during flow section rendering.
    struct SectionContext {
        let resource: Int
        let chapterURL: URL
        let rootFolder: URL
        let spineLookup: [URL: Int]
        let mediaType: String?
        let pathExtension: String

        init(
            resource: Int,
            chapterURL: URL,
            rootFolder: URL,
            spineLookup: [URL: Int],
            mediaType: String? = nil,
            pathExtension: String? = nil
        ) {
            self.resource = resource
            self.chapterURL = chapterURL
            self.rootFolder = rootFolder
            self.spineLookup = spineLookup
            self.mediaType = mediaType
            self.pathExtension = pathExtension ?? chapterURL.pathExtension
        }
    }

    /// Rewrites same-chapter and cross-chapter internal links into namespaced hash anchors (`#hc-r{target}-{id}`).
    static func rewriteInternalLinks(
        in body: Element,
        context: SectionContext
    ) throws {
        let chapterDir = URL(fileURLWithPath: context.chapterURL.deletingLastPathComponent().path, isDirectory: true)
        let standardizedRoot = context.rootFolder.resolvingSymlinksInPath().standardizedFileURL

        for el in try body.select("a[href]") {
            let rawHref = try el.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawHref.isEmpty else { continue }

            if rawHref.hasPrefix("#") {
                let fragment = String(rawHref.dropFirst())
                if !fragment.isEmpty {
                    try el.attr("href", "#hc-r\(context.resource)-\(fragment)")
                }
                continue
            }

            if let scheme = URLComponents(string: rawHref)?.scheme, !scheme.isEmpty {
                continue
            }

            let parts = rawHref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let rawPath = String(parts[0])
            let fragment = parts.count > 1 ? String(parts[1]) : nil

            let decodedPath = rawPath.removingPercentEncoding ?? rawPath
            let resolvedURL: URL
            if decodedPath.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: String(decodedPath.dropFirst()), relativeTo: standardizedRoot)
                    .absoluteURL.resolvingSymlinksInPath().standardizedFileURL
            } else {
                resolvedURL = URL(fileURLWithPath: decodedPath, relativeTo: chapterDir)
                    .absoluteURL.resolvingSymlinksInPath().standardizedFileURL
            }

            if let targetResource = context.spineLookup[resolvedURL] {
                if let fragment, !fragment.isEmpty {
                    try el.attr("href", "#hc-r\(targetResource)-\(fragment)")
                } else {
                    try el.attr("href", "#hc-r\(targetResource)")
                }
            }
        }
    }

    /// Renders a single chapter's HTML content inside a `<section class="hc-chapter">` wrapper.
    static func renderSectionHTML(
        html: String,
        context: SectionContext,
        options: ChapterTransformOptions = .init(),
        urlScheme: String? = defaultScheme
    ) throws -> String {
        let syntax = ChapterMarkup.syntax(mediaType: context.mediaType, pathExtension: context.pathExtension)
        let parsedDoc = try? ChapterMarkup.parse(html, syntax: syntax)
        var targetBody = parsedDoc.flatMap { try? ChapterMarkup.body(of: $0) }
        var activeDoc = parsedDoc
        if targetBody == nil {
            let htmlDoc = try? ChapterMarkup.parse(html, syntax: .html)
            targetBody = htmlDoc.flatMap { try? ChapterMarkup.body(of: $0) }
            activeDoc = htmlDoc
        }
        guard let body = targetBody, let document = activeDoc else {
            return "<section class=\"hc-chapter\" id=\"hc-r\(context.resource)\" data-resource=\"\(context.resource)\"></section>"
        }

        try ChapterMarkup.removeActiveContent(in: body)
        try ChapterTransforms.apply(
            options: options,
            hidePrefaceHeading: context.resource == 0,
            to: body
        )
        if options.harvestStyles {
            try ChapterStyles.apply(
                to: document,
                body: body,
                chapterURL: context.chapterURL,
                rootFolder: context.rootFolder
            )
        }
        try namespaceElementIDs(in: body, resource: context.resource)
        try rewriteInternalLinks(in: body, context: context)
        try ChapterURLs.rewrite(
            in: body,
            chapterURL: context.chapterURL,
            root: context.rootFolder,
            scheme: urlScheme
        )

        let bodyHTML = try ChapterMarkup.bodyHTML(of: body)
        return """
        <section class=\"hc-chapter\" id=\"hc-r\(context.resource)\" data-resource=\"\(context.resource)\">
        \(bodyHTML)
        </section>
        """
    }

    /// Renders a single spine item from the package.
    static func renderSection(
        resource: Int,
        package: EPUBPackage,
        spineLookup: [URL: Int],
        options: ChapterTransformOptions = .init(),
        urlScheme: String? = defaultScheme
    ) throws -> String {
        guard resource >= 0, resource < package.spineURLs.count else { return "" }
        let chapterURL = package.spineURLs[resource]
        guard let data = try? Data(contentsOf: chapterURL) else {
            return "<section class=\"hc-chapter\" id=\"hc-r\(resource)\" data-resource=\"\(resource)\"></section>"
        }
        let decoded = ChapterDecoder.decode(data).text
        let mediaType = package.manifest[chapterURL.lastPathComponent]?.mediaType
        let context = SectionContext(
            resource: resource,
            chapterURL: chapterURL,
            rootFolder: package.rootFolder,
            spineLookup: spineLookup,
            mediaType: mediaType,
            pathExtension: chapterURL.pathExtension
        )
        return try renderSectionHTML(
            html: decoded,
            context: context,
            options: options,
            urlScheme: urlScheme
        )
    }

    /// Wraps concatenated sections into a full HTML document with shared styles.
    static func wrapSections(
        sections: [String],
        language: String?,
        cosmetics: ReaderCosmeticSettings = .default,
        hideImages: Bool = false
    ) -> String {
        let languageAttribute = language.map { " lang=\"\($0)\"" } ?? ""
        let content = sections.joined(separator: "\n")

        return """
        <!doctype html>
        <html\(languageAttribute)>
        <head>
            <meta charset=\"utf-8\">
            <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
            <style id=\"honeycrisp-vars\">\(EPUBParser.readerVarsCSS(cosmetics))</style>
            <style>\(EPUBParser.readerCSS)</style>
            <style>\(EPUBParser.imageVisibilityCSS(hideImages: hideImages))</style>
        </head>
        <body>
        <div id=\"content\">
        \(content)
        </div>
        </body>
        </html>
        """
    }

    /// Builds the full multi-chapter flow document for the package.
    static func buildDocument(
        package: EPUBPackage,
        options: ChapterTransformOptions = .init(),
        cosmetics: ReaderCosmeticSettings = .default,
        hideImages: Bool = false,
        urlScheme: String? = defaultScheme
    ) throws -> String {
        let spineLookup = buildSpineLookup(spineURLs: package.spineURLs)
        let sections = try ChapterPipeline.renderAll(count: package.spineURLs.count) { resource in
            try renderSection(
                resource: resource,
                package: package,
                spineLookup: spineLookup,
                options: options,
                urlScheme: urlScheme
            )
        }
        return wrapSections(
            sections: sections,
            language: package.language,
            cosmetics: cosmetics,
            hideImages: hideImages
        )
    }

    /// Builds a single-chapter paged document for horizontal CSS multi-column pagination.
    static func buildPagedDocument(
        resource: Int,
        package: EPUBPackage,
        columnCSS: String,
        options: ChapterTransformOptions = .init(),
        cosmetics: ReaderCosmeticSettings = .default,
        hideImages: Bool = false,
        urlScheme: String? = defaultScheme
    ) throws -> String {
        let spineLookup = buildSpineLookup(spineURLs: package.spineURLs)
        let section = try renderSection(
            resource: resource,
            package: package,
            spineLookup: spineLookup,
            options: options,
            urlScheme: urlScheme
        )
        let languageAttribute = package.language.map { " lang=\"\($0)\"" } ?? ""
        return """
        <!doctype html>
        <html\(languageAttribute)>
        <head>
            <meta charset=\"utf-8\">
            <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
            <style id=\"honeycrisp-vars\">\(EPUBParser.readerVarsCSS(cosmetics))</style>
            <style>\(EPUBParser.readerCSS)</style>
            <style>\(columnCSS)</style>
            <style>\(EPUBParser.imageVisibilityCSS(hideImages: hideImages))</style>
            <style>
            body { padding: 0 !important; }
            html { visibility: hidden; }
            </style>
        </head>
        <body>
        <div id=\"content\">
        \(section)
        </div>
        </body>
        </html>
        """
    }
}
