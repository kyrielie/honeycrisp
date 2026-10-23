import Foundation
import WebKit

/// Flow surface implementation (FRAMEWORK contract C5, roadmap M4a).
/// Renders an EPUB as a continuous multi-chapter flow document served under `honeycrisp-epub://`
/// via `EPUBResourceSchemeHandler`. Author JavaScript is disabled (`allowsContentJavaScript = false`),
/// app scripts run in `WKContentWorld.defaultClient`, and navigation is constrained to in-book resources.
@MainActor
final class FlowSurface: FlowingSurface {
    /// App resource path of the flow document.
    static let flowResourcePath = "__app/flow.html"

    /// Default Content-Security-Policy applied to flow responses.
    static let defaultCSP = "default-src 'self' honeycrisp-epub:; script-src 'none'; "
        + "style-src 'self' 'unsafe-inline' honeycrisp-epub:; "
        + "img-src 'self' honeycrisp-epub: data:; "
        + "font-src 'self' honeycrisp-epub:;"

    let schemeHandler: EPUBResourceSchemeHandler

    var pagerContentWorld: WKContentWorld? { .defaultClient }
    var supportsBookmarks: Bool { true }
    var persistsProgress: Bool { true }
    var persistsPosition: Bool { true }
    var requiresEngineReadyForSpineNavigation: Bool { false }
    var managesScrollWindow: Bool { false }
    var managesPagedChapter: Bool { false }
    var handlesReadingModeToggle: Bool { false }
    var handlesStructuralReload: Bool { false }
    var handlesPaginatedResize: Bool { false }

    var onProgress: ((Int) -> Void)?
    var onPosition: ((_ resource: Int, _ offset: Int, _ fraction: Double) -> Void)?
    var onPageInfo: ((Int, Int, Int, Int) -> Void)?
    var onPageAction: ((Bool) -> Void)?
    var onPositionUpdate: ((Int?, Int?) -> Void)?

    init(schemeHandler: EPUBResourceSchemeHandler = EPUBResourceSchemeHandler(rootFolder: URL(fileURLWithPath: "/"))) {
        self.schemeHandler = schemeHandler
        self.schemeHandler.responseHeaders["Content-Security-Policy"] = Self.defaultCSP
    }

    /// App-scheme URL for the flow document.
    var documentURL: URL? {
        URL(string: "\(EPUBResourceSchemeHandler.scheme)://book/\(Self.flowResourcePath)")
    }

    /// Points the scheme handler at the package root and stores the prepared flow document.
    func attach(package: EPUBPackage, html: String) {
        schemeHandler.rootFolder = package.rootFolder
        schemeHandler.appResources[Self.flowResourcePath] = Data(html.utf8)
    }

    func install(into configuration: WKWebViewConfiguration) {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBResourceSchemeHandler.scheme)

        let script = WKUserScript(
            source: EPUBParser.readerJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        )
        configuration.userContentController.addUserScript(script)
        installMessageHandlers(into: configuration.userContentController)
    }

    private func installMessageHandlers(into controller: WKUserContentController) {
        let names = ["progressHandler", "positionHandler", "pageInfoHandler", "pageAction", "positionUpdate"]
        for name in names {
            let handler = FlowScriptMessageHandler(surface: self, handlerName: name)
            controller.add(handler, contentWorld: .defaultClient, name: name)
        }
    }

    func applyCosmetics(_ cosmetics: ReaderCosmeticSettings, to webView: WKWebView, mode: ReadingMode) async throws {
        guard let cssLiteral = EPUBParser.javaScriptStringLiteral(EPUBParser.readerVarsCSS(cosmetics)) else { return }
        let js = """
            (function() {
              var el = document.getElementById('honeycrisp-vars');
              if (el) el.textContent = \(cssLiteral);
            })();
            """
        _ = try await webView.evaluateJavaScript(js, in: nil, in: .defaultClient)
        if mode == .scroll {
            _ = try? await webView.evaluateJavaScript(
                "window.reportPageInfo && window.reportPageInfo();", in: nil, in: .defaultClient)
        }
    }

    func allowsNavigation(action: WKNavigationAction, currentURL: URL?) -> Bool {
        Self.allowsNavigation(to: action.request.url)
    }

    nonisolated static func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == EPUBResourceSchemeHandler.scheme {
            return url.host == "book"
        }
        return url.absoluteString == "about:blank"
    }

    func didFinishNavigation(
        in webView: WKWebView,
        paginationEngine: PaginationEngine?,
        colsPerScreen: ColsPerScreen
    ) -> Bool {
        false
    }

    func targetForPaginatedRestore(fallbackIndex: Int, count: Int) -> (index: Int, restore: RestorePosition)? {
        nil
    }

    func didReceiveMessage(name: String, body: Any) {
        switch name {
        case "progressHandler":
            if let pct = body as? Int { onProgress?(pct) }
        case "positionHandler":
            handlePositionMessage(body)
        case "pageInfoHandler":
            handlePageInfoMessage(body)
        case "pageAction":
            handlePageActionMessage(body)
        case "positionUpdate":
            handlePositionUpdateMessage(body)
        default:
            break
        }
    }

    private func handlePositionMessage(_ body: Any) {
        if let dict = body as? [String: Any] {
            let resource = (dict["resource"] as? NSNumber)?.intValue ?? (dict["resource"] as? Int) ?? 0
            let offset = (dict["offset"] as? NSNumber)?.intValue ?? (dict["offset"] as? Int) ?? 0
            let fraction = (dict["fraction"] as? NSNumber)?.doubleValue ?? (dict["fraction"] as? Double) ?? 0.0
            onPosition?(resource, offset, fraction)
            return
        }
        if let offset = (body as? NSNumber)?.intValue ?? (body as? Int) {
            onPosition?(0, offset, 0.0)
        }
    }

    private func handlePageInfoMessage(_ body: Any) {
        guard let str = body as? String,
            let data = str.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let page = (dict["page"] as? NSNumber)?.intValue,
            let totalPages = (dict["totalPages"] as? NSNumber)?.intValue,
            let spineIndex = (dict["spineIndex"] as? NSNumber)?.intValue,
            let spineCount = (dict["spineCount"] as? NSNumber)?.intValue
        else { return }
        onPageInfo?(page, totalPages, spineIndex, spineCount)
    }

    private func handlePageActionMessage(_ body: Any) {
        guard let str = body as? String,
            let data = str.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = dict["action"] as? String
        else { return }
        onPageAction?(action == "nextSpineItem")
    }

    private func handlePositionUpdateMessage(_ body: Any) {
        guard let str = body as? String,
            let data = str.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            onPositionUpdate?(nil, nil)
            return
        }
        let column = (dict["column"] as? NSNumber)?.intValue
        let total = (dict["totalColumns"] as? NSNumber)?.intValue
        onPositionUpdate?(column, total)
    }
}

private final class FlowScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var surface: FlowSurface?
    private let handlerName: String

    init(surface: FlowSurface, handlerName: String) {
        self.surface = surface
        self.handlerName = handlerName
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        surface?.didReceiveMessage(name: handlerName, body: message.body)
    }
}
