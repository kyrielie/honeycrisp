import Foundation
import WebKit

/// Serves unpacked EPUB resources through a private URL scheme. The resolver is
/// kept pure so path containment can be tested without constructing WebKit tasks.
final class EPUBResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "honeycrisp-epub"

    private let rootFolder: URL

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

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
            let fileURL = Self.resourceURL(for: url, root: rootFolder)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL)
                let response = URLResponse(
                    url: url, mimeType: Self.mimeType(for: fileURL),
                    expectedContentLength: data.count, textEncodingName: "utf-8")
                DispatchQueue.main.async {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                DispatchQueue.main.async { urlSchemeTask.didFailWithError(error) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
