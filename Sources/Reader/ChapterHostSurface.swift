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
/// images, spacer collapsing and paginated mode are not ported (M4, M5, M6).
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

    /// App resource key of the shell document (see `ChapterHostShell`).
    static let shellResourcePath = "__app/shell.html"

    /// Must run before the `WKWebView` is created from `configuration`, and after the configuration's
    /// `userContentController` is final (the sizing script is added to it).
    func install(into configuration: WKWebViewConfiguration) {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBResourceSchemeHandler.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ChapterHostScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                in: .defaultClient))
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
        let language = servedLanguage
        let userCSS = ChapterHostCSS.userBlock(cosmetics)
        schemeHandler.transform = { ServedChapter.prepare($0, language: language, userCSS: userCSS) }
    }

    /// Live cosmetic change (C8): no reload, no navigation. Updates what the handler serves for chapters
    /// mounted later, then replaces the text of `<style id="honeycrisp-user">` in every mounted chapter
    /// document through the client world. The CSS travels as a `callAsyncJavaScript` argument, never in
    /// the script source. Returns the number of chapter documents patched; 0 when no window is mounted.
    @discardableResult
    func applyCosmetics(_ cosmetics: ReaderCosmeticSettings, to webView: WKWebView) async throws -> Int {
        updateServedCosmetics(cosmetics)
        let result = try await webView.callAsyncJavaScript(
            "return window.honeycrispHost ? window.honeycrispHost.applyUserCSS(css) : 0;",
            arguments: ["css": ChapterHostCSS.userBlock(cosmetics)], in: nil, contentWorld: .defaultClient)
        return (result as? NSNumber)?.intValue ?? 0
    }

    func load(resource index: Int, in package: EPUBPackage, into webView: WKWebView) throws {
        guard package.spineURLs.indices.contains(index),
            let url = Self.chapterURL(for: package.spineURLs[index], root: package.rootFolder)
        else { throw SpikeError.chapterUnavailable(index) }
        webView.load(URLRequest(url: url))
    }

    /// Mounts the chapter at `index` and its neighbours as isolated iframes in the shell document.
    /// No eviction or scroll bookkeeping yet (M4): the window is static until the next call.
    func loadWindow(around index: Int, in package: EPUBPackage, into webView: WKWebView) throws {
        var frames: [ChapterHostShell.Frame] = []
        for resource in Self.windowIndices(around: index, count: package.spineURLs.count) {
            guard let path = Self.chapterPath(for: package.spineURLs[resource], root: package.rootFolder) else {
                throw SpikeError.chapterUnavailable(resource)
            }
            frames.append(ChapterHostShell.Frame(resource: resource, path: path))
        }
        var components = URLComponents()
        components.scheme = EPUBResourceSchemeHandler.scheme
        components.host = "book"
        components.path = "/" + Self.shellResourcePath
        guard !frames.isEmpty, let shellURL = components.url else { throw SpikeError.chapterUnavailable(index) }
        schemeHandler.appResources[Self.shellResourcePath] = Data(ChapterHostShell.html(frames: frames).utf8)
        webView.load(URLRequest(url: shellURL))
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
    func firstVisiblePosition(in webView: WKWebView, x: Double? = nil) async throws -> Position? {
        let argument: Any = x.map { $0 as Any } ?? NSNull()
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
