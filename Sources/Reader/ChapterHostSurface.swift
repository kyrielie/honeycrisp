import Foundation
import WebKit

/// Gate for the chapter host spike (roadmap M3). Off unless the process environment has
/// `HONEYCRISP_CHAPTER_HOST=1` (set it in the Xcode scheme). Deliberately not a persisted setting.
enum ChapterHostFlag {
    static let environmentKey = "HONEYCRISP_CHAPTER_HOST"

    static var isEnabled: Bool { isEnabled(environment: ProcessInfo.processInfo.environment) }

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }
}

/// Spike surface (roadmap M3, contracts C4 to C6): shows one served chapter, as its own document, in the
/// reader's web view instead of the merged document. Author JavaScript is off, resources come from
/// `EPUBResourceSchemeHandler`, and `ChapterHostCSS` supplies the user layer. Flag mode is a read-only
/// viewer: position, progress, search, speech, bookmarks, TOC jumps, AO3 and indent transforms, hide
/// images, spacer collapsing and paginated mode are not ported (M4, M5, M6). Scroll mode windows over the
/// whole spine (M4 pass 2): see `ChapterHostShell` and `ChapterHostScript`.
@MainActor
final class ChapterHostSurface {
    enum SpikeError: LocalizedError {
        case pagedModeUnsupported
        case chapterUnavailable(Int)

        var errorDescription: String? {
            switch self {
            case .pagedModeUnsupported:
                return "Paginated mode is not available while the chapter host spike is enabled."
            case .chapterUnavailable(let index):
                return "Chapter \(index + 1) could not be shown by the chapter host spike."
            }
        }
    }

    let schemeHandler: EPUBResourceSchemeHandler

    init() {
        // Placeholder root: the web view is built before any book is open. `attach` points it at the book.
        schemeHandler = EPUBResourceSchemeHandler(rootFolder: FileManager.default.temporaryDirectory)
    }

    /// Client-world message handler the shell script posts the reading position to (see `ChapterHostScript`).
    static let positionHandlerName = "hostPosition"

    /// Called on the main thread when scrolling settles: the chapter and offset on the reference line (C2) and
    /// the page within that chapter (a window height is a page). Never persisted by the surface.
    var onPositionChange: ((Position, _ chapterPage: Int, _ chapterPages: Int) -> Void)?

    /// How the web view currently presents chapters: the scrolling shell with iframes, or one chapter as the
    /// top-level document laid out in columns (roadmap M4, pass 6).
    enum Presentation: Equatable {
        case scroll
        case paged(ChapterHostPagedGeometry)
    }

    private(set) var presentation: Presentation = .scroll

    /// Paged chapter edge: the pager asked for the next (`true`) or previous (`false`) chapter.
    var onPageAction: ((_ forward: Bool) -> Void)?

    /// Paged chapter: column and column count after a page turn or restore (either may be missing).
    var onPagerPosition: ((_ column: Int?, _ total: Int?) -> Void)?

    func receivePageAction(_ body: Any) {
        guard let json = body as? String,
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
            let action = object["action"]
        else { return }
        if action == "nextSpineItem" { onPageAction?(true) } else if action == "prevSpineItem" { onPageAction?(false) }
    }

    func receivePagerPosition(_ body: Any) {
        guard let json = body as? String,
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { onPagerPosition?(nil, nil); return }
        onPagerPosition?((object["column"] as? NSNumber)?.intValue, (object["totalColumns"] as? NSNumber)?.intValue)
    }

    /// Where `loadWindow` lands. `start` is the top of the chapter, `position` a text offset on the reference
    /// line, `fraction` a share of the chapter's height.
    enum Restore: Equatable {
        case start
        case position(Position)
        case fraction(resource: Int, fraction: Double)
    }

    /// Decodes one `hostPosition` message (a JSON string of four integers); anything else is ignored.
    func receivePosition(_ body: Any) {
        guard let json = body as? String,
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int],
            let resource = object["resource"], let offset = object["offset"],
            let page = object["chapterPage"], let pages = object["chapterPages"],
            resource >= 0, offset >= 0, pages >= 1, (1...pages).contains(page)
        else { return }
        onPositionChange?(Position(resource: resource, offset: offset), page, pages)
    }

    /// App resource key of the shell document (see `ChapterHostShell`).
    static let shellResourcePath = "__app/shell.html"

    /// Must run before the `WKWebView` is created from `configuration`, and after the configuration's
    /// `userContentController` is final (the sizing script is added to it).
    func install(into configuration: WKWebViewConfiguration) {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBResourceSchemeHandler.scheme)
        Self.installScripts(into: configuration.userContentController, pager: nil)
        let controller = configuration.userContentController
        controller.add(
            ChapterHostPositionHandler(surface: self), contentWorld: .defaultClient, name: Self.positionHandlerName)
        // The paged chapter's pager (PaginationJS) posts through these two names, as in the merged document, but
        // from the client world (assumption V1).
        controller.add(ChapterHostPagerHandler(surface: self, kind: .pageAction), contentWorld: .defaultClient, name: "pageAction")
        controller.add(
            ChapterHostPagerHandler(surface: self, kind: .positionUpdate), contentWorld: .defaultClient, name: "positionUpdate")
    }

    /// `WKUserContentController` cannot remove one script, so the surface owns the whole list: the host script
    /// and, for a paged chapter, its pager bootstrap. Re-applied before every load (assumption V2).
    private static func installScripts(into controller: WKUserContentController, pager: String?) {
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(source: ChapterHostScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        if let pager {
            controller.addUserScript(
                WKUserScript(source: pager, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
    }

    /// Points the handler at the book and installs the stylesheet and the markup transform for the
    /// given settings. Call again after a structural change; chapters already loaded keep their CSS.
    func attach(package: EPUBPackage, cosmetics: ReaderCosmeticSettings) {
        schemeHandler.rootFolder = package.rootFolder
        schemeHandler.appResources[ServedChapter.readerStylesheetPath] = Data(ChapterHostCSS.stylesheet.utf8)
        servedLanguage = package.language
        updateServedCosmetics(cosmetics)
    }

    /// Root `lang` for chapters that have none, from the attached package.
    private var servedLanguage: String?

    /// Chapters served from now on carry `cosmetics` in their inline user block. Chapters already
    /// mounted are not touched; `applyCosmetics` patches those. Main thread only, like `attach`.
    func updateServedCosmetics(_ cosmetics: ReaderCosmeticSettings) {
        servedCosmetics = cosmetics
        let language = servedLanguage
        let userCSS = userCSS(for: cosmetics)
        schemeHandler.transform = { ServedChapter.prepare($0, language: language, userCSS: userCSS) }
    }

    private var servedCosmetics: ReaderCosmeticSettings?

    /// The user block, plus the column CSS while a chapter is presented paged (C4/C8: geometry is part of the
    /// user layer, so a cosmetic patch must not drop it).
    private func userCSS(for cosmetics: ReaderCosmeticSettings) -> String {
        var css = ChapterHostCSS.userBlock(cosmetics)
        if case .paged(let geometry) = presentation { css += "\n" + ChapterHostCSS.pagedBlock(columnCSS: geometry.columnCSS) }
        return css
    }

    /// Live cosmetic change (C8): no reload, no navigation. Updates what the handler serves for chapters
    /// mounted later, then replaces the text of `<style id="honeycrisp-user">` in every mounted chapter
    /// document through the client world. The CSS travels as a `callAsyncJavaScript` argument, never in
    /// the script source. Returns the number of chapter documents patched; 0 when no window is mounted.
    @discardableResult
    func applyCosmetics(_ cosmetics: ReaderCosmeticSettings, to webView: WKWebView) async throws -> Int {
        updateServedCosmetics(cosmetics)
        if case .paged(let geometry) = presentation {
            // One document, no iframes: replace its user block, recount the columns and re-seek by fraction
            // (an exact offset would need an "offset at the current column" function; roadmap N3).
            let patched = try await webView.callAsyncJavaScript(
                """
                var style = document.getElementById('honeycrisp-user');
                if (!style || !window.qlSetup) { return 0; }
                var before = window.qlProgressFraction();
                style.textContent = css;
                window.qlSetup(cols);
                window.qlScrollToFraction(before);
                return 1;
                """,
                arguments: ["css": userCSS(for: cosmetics), "cols": geometry.colsPerScreen.rawValue], in: nil,
                contentWorld: .defaultClient)
            return (patched as? NSNumber)?.intValue ?? 0
        }
        let result = try await webView.callAsyncJavaScript(
            "return window.honeycrispHost ? window.honeycrispHost.applyUserCSS(css) : 0;",
            arguments: ["css": ChapterHostCSS.userBlock(cosmetics)], in: nil, contentWorld: .defaultClient)
        return (result as? NSNumber)?.intValue ?? 0
    }

    /// Loads one chapter as the top-level document, laid out in columns by the shared pager. The geometry is
    /// stored, so cosmetic updates keep it. The pager script is added for this load only (V2): `restore` is
    /// baked into it as numbers. The document stays hidden until the bootstrap has restored the column.
    func loadPaged(
        resource index: Int, in package: EPUBPackage, into webView: WKWebView, geometry: ChapterHostPagedGeometry,
        restore: RestorePosition
    ) throws {
        guard package.spineURLs.indices.contains(index),
            let url = Self.chapterURL(for: package.spineURLs[index], root: package.rootFolder)
        else { throw SpikeError.chapterUnavailable(index) }
        presentation = .paged(geometry)
        if let servedCosmetics { updateServedCosmetics(servedCosmetics) }
        Self.installScripts(
            into: webView.configuration.userContentController,
            pager: ChapterHostCSS.pagerBootstrap(cols: geometry.colsPerScreen, restore: restore))
        webView.load(URLRequest(url: url))
    }

    func load(resource index: Int, in package: EPUBPackage, into webView: WKWebView) throws {
        guard package.spineURLs.indices.contains(index),
            let url = Self.chapterURL(for: package.spineURLs[index], root: package.rootFolder)
        else { throw SpikeError.chapterUnavailable(index) }
        webView.load(URLRequest(url: url))
    }

    /// Placeholder for the first estimate of a chapter's height, in px per byte of XHTML. The client script
    /// replaces it with a measured ratio (pass 3); tune from the first measured fixture (decision N2).
    static var initialPixelsPerByte: Double { ChapterHostShell.initialPixelsPerByte }

    /// Height in px assumed for a chapter that has not been measured: never less than the viewport, and
    /// growing with the chapter's byte size. Pure.
    nonisolated static func estimatedHeight(
        byteCount: Int, viewportHeight: Double, pixelsPerByte: Double = ChapterHostShell.initialPixelsPerByte
    ) -> Int {
        let estimate = Double(max(0, byteCount)) * max(0, pixelsPerByte)
        return Int(max(max(0, viewportHeight), estimate).rounded())
    }

    /// Builds the shell with one slot per spine item and mounts the chapter at `index` and its neighbours
    /// (`windowIndices`). The client script mounts and evicts further chapters as the shell scrolls. A chapter
    /// outside the initial window whose path cannot be resolved is left out of the shell; one inside it throws.
    func loadWindow(
        around index: Int, in package: EPUBPackage, into webView: WKWebView, restoring: Restore? = nil
    ) throws {
        let target: Int
        let shellRestore: ChapterHostShell.Restore?
        switch restoring {
        case nil:
            target = index
            shellRestore = nil
        case .start?:
            target = index
            shellRestore = .init(resource: index, offset: nil, fraction: nil)
        case .position(let position)?:
            target = position.resource
            shellRestore = .init(resource: position.resource, offset: position.offset, fraction: nil)
        case .fraction(let resource, let fraction)?:
            target = resource
            shellRestore = .init(resource: resource, offset: nil, fraction: fraction)
        }
        presentation = .scroll
        if let servedCosmetics { updateServedCosmetics(servedCosmetics) }
        Self.installScripts(into: webView.configuration.userContentController, pager: nil)
        let initial = Set(Self.windowIndices(around: target, count: package.spineURLs.count))
        let viewportHeight = Double(webView.bounds.height)
        var slots: [ChapterHostShell.Slot] = []
        for (resource, url) in package.spineURLs.enumerated() {
            guard let path = Self.chapterPath(for: url, root: package.rootFolder) else {
                if initial.contains(resource) { throw SpikeError.chapterUnavailable(resource) }
                continue
            }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            slots.append(
                ChapterHostShell.Slot(
                    resource: resource, path: path, byteCount: bytes,
                    estimatedHeight: Self.estimatedHeight(byteCount: bytes, viewportHeight: viewportHeight),
                    mounted: initial.contains(resource)))
        }
        var components = URLComponents()
        components.scheme = EPUBResourceSchemeHandler.scheme
        components.host = "book"
        components.path = "/" + Self.shellResourcePath
        guard !initial.isEmpty, let shellURL = components.url else { throw SpikeError.chapterUnavailable(index) }
        let shellHTML = ChapterHostShell.html(
            slots: slots, restore: shellRestore.map { clamped($0, count: package.spineURLs.count) })
        schemeHandler.appResources[Self.shellResourcePath] = Data(shellHTML.utf8)
        webView.load(URLRequest(url: shellURL))
        if shellRestore != nil {
            // The shell stays hidden until the script has restored. If it never reports (a chapter failed to
            // load), show it anyway after a while.
            Task { @MainActor [weak webView] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                _ = try? await webView?.callAsyncJavaScript(
                    "if (window.honeycrispHost) { window.honeycrispHost.reveal(); }", arguments: [:], in: nil,
                    contentWorld: .defaultClient)
            }
        }
    }

    /// Keeps the restore target inside the book, so the attribute always names an existing slot.
    private func clamped(_ restore: ChapterHostShell.Restore, count: Int) -> ChapterHostShell.Restore {
        .init(resource: min(max(restore.resource, 0), max(0, count - 1)), offset: restore.offset, fraction: restore.fraction)
    }

    /// A reading position in the host: a chapter (spine index) and a UTF-16 offset in that chapter's body
    /// text-node walk (contract C2). Not persisted anywhere yet.
    struct Position: Equatable {
        let resource: Int
        let offset: Int
    }

    /// The text on the reference line (a third of the way down the window), or nil when the line has no
    /// text caret or no chapter is mounted under it. `x` defaults to the window's center, as in the merged
    /// reader; pass a value to read at a specific column.
    func firstVisiblePosition(in webView: WKWebView, x column: Double? = nil) async throws -> Position? {
        let argument: Any = column.map { $0 as Any } ?? NSNull()
        let result = try await webView.callAsyncJavaScript(
            "return window.honeycrispHost ? JSON.stringify(window.honeycrispHost.offsetOfFirstVisibleText(x)) : 'null';",
            arguments: ["x": argument], in: nil, contentWorld: .defaultClient)
        guard let json = result as? String, json != "null",
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int],
            let resource = object["resource"], let offset = object["offset"]
        else { return nil }
        return Position(resource: resource, offset: offset)
    }

    /// Scrolls so `position` sits on the reference line. False when the chapter is not mounted.
    @discardableResult
    func scroll(to position: Position, in webView: WKWebView) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(
            "return window.honeycrispHost ? window.honeycrispHost.scrollTo(resource, offset) : false;",
            arguments: ["resource": position.resource, "offset": position.offset], in: nil,
            contentWorld: .defaultClient)
        return (result as? NSNumber)?.boolValue ?? false
    }

    /// The chapter at `index` plus `radius` neighbours on each side, clamped to the book. `index` itself is
    /// clamped first, so a stale index still yields a window. Empty for an empty book.
    nonisolated static func windowIndices(around index: Int, count: Int, radius: Int = 1) -> [Int] {
        guard count > 0 else { return [] }
        let center = min(max(index, 0), count - 1)
        return Array(max(0, center - radius)...min(count - 1, center + radius))
    }

    /// The percent-encoded absolute path of `chapterURL`, for use as an iframe `src` in the shell.
    nonisolated static func chapterPath(for resource: URL, root: URL) -> String? {
        guard let url = chapterURL(for: resource, root: root) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    }

    /// `honeycrisp-epub://book/<percent-encoded path relative to root>`, or nil when `resource` is the
    /// root itself or lies outside it.
    nonisolated static func chapterURL(for resource: URL, root: URL) -> URL? {
        let rootPath = normalizedPath(root)
        let resourcePath = normalizedPath(resource)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resourcePath.hasPrefix(prefix), resourcePath.count > prefix.count else { return nil }
        var components = URLComponents()
        components.scheme = EPUBResourceSchemeHandler.scheme
        components.host = "book"
        components.path = "/" + resourcePath.dropFirst(prefix.count)
        return components.url
    }

    /// Both sides of the containment check go through the same resolution, and a leading `/private` is
    /// dropped because Foundation resolves `/var` and `/private/var` inconsistently for paths that do
    /// not exist yet.
    private nonisolated static func normalizedPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// Flag-mode navigation policy (C6): only the app scheme and `about:blank` may load; everything else
    /// (file, data, javascript, remote) is cancelled. http and https link clicks are handled earlier by
    /// the reader, which opens them in the browser.
    nonisolated static func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == EPUBResourceSchemeHandler.scheme || url.absoluteString == "about:blank"
    }
}
