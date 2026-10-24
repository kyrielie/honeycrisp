import Foundation
import WebKit

/// In-flight scheme tasks, so a task WebKit has stopped is never completed afterwards. Pure and
/// main-thread only, so it can be tested without constructing WebKit tasks.
struct ActiveTaskSet {
    private var ids: Set<ObjectIdentifier> = []

    mutating func insert(_ id: ObjectIdentifier) { ids.insert(id) }

    /// True when `id` was active. Callers complete a task only when this returns true.
    @discardableResult
    mutating func remove(_ id: ObjectIdentifier) -> Bool { ids.remove(id) != nil }

    func contains(_ id: ObjectIdentifier) -> Bool { ids.contains(id) }
}

/// Serves unpacked EPUB resources through a private URL scheme. The resolver is
/// kept pure so path containment can be tested without constructing WebKit tasks.
/// Not wired into the reader yet (roadmap M3); all members are main-thread only. Besides book files it
/// serves app-generated resources under `/__app/` (`appResources`) and can prepare chapter markup
/// (`transform`, see `ServedChapter`).
final class EPUBResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "honeycrisp-epub"

    /// Settable so a configuration built before the book is parsed can be pointed at it later.
    var rootFolder: URL {
        didSet { rootFolder = rootFolder.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// Extra response headers (for example `Content-Security-Policy`). Empty keeps the plain
    /// `URLResponse` the handler always sent.
    var responseHeaders: [String: String] = [:]

    /// App-generated resources keyed by path without the leading slash (for example
    /// `ServedChapter.readerStylesheetPath`). Looked up before any book file, so a book directory named
    /// `__app` can never shadow them. Not book bytes.
    var appResources: [String: Data] = [:]

    /// Applied to chapter markup (`shouldTransform`) after it is read and before it is served. Runs on a
    /// background queue; keep it pure.
    var transform: ((Data) -> Data)?

    private var activeTasks = ActiveTaskSet()

    init(rootFolder: URL) {
        self.rootFolder = rootFolder.resolvingSymlinksInPath().standardizedFileURL
    }

    static func resourceURL(for url: URL, root: URL) -> URL? {
        guard url.scheme == scheme, url.host == "book", url.query == nil else { return nil }
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard let relativePath = encodedPath.removingPercentEncoding,
            !relativePath.isEmpty,
            !relativePath.split(separator: "/").contains("..")
        else { return nil }
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let target = rootURL.appendingPathComponent(relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(rootURL.path + "/") else { return nil }
        return target
    }

    /// Key into `appResources` when `url` addresses an app resource (`/__app/...`), else nil. Same
    /// containment rules as `resourceURL`: our scheme, host `book`, no query, no `..` segments.
    static func appResourceKey(for url: URL) -> String? {
        guard url.scheme == scheme, url.host == "book", url.query == nil else { return nil }
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard let path = encodedPath.removingPercentEncoding,
            path.hasPrefix("/__app/"), path.count > "/__app/".count,
            !path.split(separator: "/").contains("..")
        else { return nil }
        return String(path.dropFirst())
    }

    /// Markup is the only content `transform` sees; images, CSS and fonts are served untouched.
    static func shouldTransform(_ url: URL) -> Bool {
        ["xhtml", "html", "htm"].contains(url.pathExtension.lowercased())
    }

    private static let mimeTypes: [String: String] = [
        "xhtml": "application/xhtml+xml",
        "html": "application/xhtml+xml",
        "htm": "application/xhtml+xml",
        "css": "text/css",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
    ]

    static func mimeType(for url: URL, isAppResource: Bool = false) -> String {
        let ext = url.pathExtension.lowercased()
        if isAppResource && (ext == "html" || ext == "htm") {
            return "text/html"
        }
        return mimeTypes[ext] ?? "application/octet-stream"
    }

    private static func response(
        for url: URL, fileURL: URL, byteCount: Int, extraHeaders: [String: String], isAppResource: Bool = false
    ) -> URLResponse {
        let mime = mimeType(for: fileURL, isAppResource: isAppResource)
        let plain = URLResponse(
            url: url, mimeType: mime, expectedContentLength: byteCount, textEncodingName: "utf-8")
        guard !extraHeaders.isEmpty else { return plain }
        var headers = extraHeaders
        headers["Content-Type"] = mime
        headers["Content-Length"] = String(byteCount)
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) ?? plain
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        if let url = urlSchemeTask.request.url, let key = Self.appResourceKey(for: url) {
            guard let data = appResources[key] else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            var headers = responseHeaders
            headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
            let response = Self.response(
                for: url, fileURL: URL(fileURLWithPath: key), byteCount: data.count,
                extraHeaders: headers, isAppResource: true)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        guard let url = urlSchemeTask.request.url,
            let fileURL = Self.resourceURL(for: url, root: rootFolder)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let extraHeaders = responseHeaders
        let transform = self.transform
        activeTasks.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let raw = try Data(contentsOf: fileURL)
                let data: Data
                if let transform, Self.shouldTransform(fileURL) { data = transform(raw) } else { data = raw }
                let response = Self.response(
                    for: url, fileURL: fileURL, byteCount: data.count, extraHeaders: extraHeaders)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeTasks.remove(id) else { return }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeTasks.remove(id) else { return }
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }
}
