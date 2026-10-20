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
/// Not wired into the reader yet (roadmap M3); all members are main-thread only.
final class EPUBResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "honeycrisp-epub"

    /// Settable so a configuration built before the book is parsed can be pointed at it later.
    var rootFolder: URL {
        didSet { rootFolder = rootFolder.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// Extra response headers (for example `Content-Security-Policy`). Empty keeps the plain
    /// `URLResponse` the handler always sent.
    var responseHeaders: [String: String] = [:]

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

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "xhtml", "html", "htm": return "application/xhtml+xml"
        case "css": return "text/css"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
        }
    }

    private static func response(
        for url: URL, fileURL: URL, byteCount: Int, extraHeaders: [String: String]
    ) -> URLResponse {
        let mime = mimeType(for: fileURL)
        let plain = URLResponse(
            url: url, mimeType: mime, expectedContentLength: byteCount, textEncodingName: "utf-8")
        guard !extraHeaders.isEmpty else { return plain }
        var headers = extraHeaders
        headers["Content-Type"] = mime
        headers["Content-Length"] = String(byteCount)
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) ?? plain
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
            let fileURL = Self.resourceURL(for: url, root: rootFolder)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let extraHeaders = responseHeaders
        activeTasks.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL)
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
