import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

final class FlowSurfaceTests: XCTestCase {
    @MainActor
    func testFlowSurfaceProtocolProperties() {
        let surface = FlowSurface()
        XCTAssertIdentical(surface.pagerContentWorld, WKContentWorld.defaultClient)
        XCTAssertTrue(surface.supportsBookmarks)
        XCTAssertTrue(surface.persistsProgress)
        XCTAssertTrue(surface.persistsPosition)
        XCTAssertFalse(surface.requiresEngineReadyForSpineNavigation)
        XCTAssertFalse(surface.managesScrollWindow)
        XCTAssertTrue(surface.managesPagedChapter)
        XCTAssertFalse(surface.handlesReadingModeToggle)
        XCTAssertFalse(surface.handlesStructuralReload)
        XCTAssertTrue(surface.handlesPaginatedResize)
    }

    func testAllowsNavigationAllowsInBookAndAboutBlank() {
        XCTAssertTrue(FlowSurface.allowsNavigation(to: URL(string: "honeycrisp-epub://book/__app/flow.html")))
        XCTAssertTrue(FlowSurface.allowsNavigation(to: URL(string: "honeycrisp-epub://book/Text/ch1.xhtml#hc-r0-p1")))
        XCTAssertTrue(FlowSurface.allowsNavigation(to: URL(string: "about:blank")))

        XCTAssertFalse(FlowSurface.allowsNavigation(to: URL(string: "file:///etc/passwd")))
        XCTAssertFalse(FlowSurface.allowsNavigation(to: URL(string: "http://example.com")))
        XCTAssertFalse(FlowSurface.allowsNavigation(to: URL(string: "https://example.com")))
        XCTAssertFalse(FlowSurface.allowsNavigation(to: URL(string: "javascript:alert(1)")))
        XCTAssertFalse(FlowSurface.allowsNavigation(to: URL(string: "honeycrisp-epub://other/path")))
        XCTAssertFalse(FlowSurface.allowsNavigation(to: nil))
    }

    func testFlowSurfaceFlagEnvironmentControl() {
        XCTAssertTrue(FlowSurfaceFlag.isEnabled(environment: [:]))
        XCTAssertTrue(FlowSurfaceFlag.isEnabled(environment: ["HONEYCRISP_FLOW": "1"]))
        XCTAssertFalse(FlowSurfaceFlag.isEnabled(environment: ["HONEYCRISP_FLOW": "0"]))
        XCTAssertFalse(FlowSurfaceFlag.isEnabled(environment: ["HONEYCRISP_LEGACY": "1"]))
        XCTAssertFalse(FlowSurfaceFlag.isEnabled(environment: ["HONEYCRISP_FLOW": "1", "HONEYCRISP_LEGACY": "1"]))
    }

    func testContentSecurityPolicyBlocksRemoteImagesAndExternalScripts() {
        let csp = FlowSurface.defaultCSP
        XCTAssertTrue(csp.contains("img-src 'self' honeycrisp-epub: data:;"))
        XCTAssertTrue(csp.contains("script-src 'none';"))
    }

    @MainActor
    func testInstallConfiguresWebKitPreferencesAndHandlers() {
        let surface = FlowSurface()
        let config = WKWebViewConfiguration()
        surface.install(into: config)

        XCTAssertFalse(config.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(surface.schemeHandler.responseHeaders["Content-Security-Policy"], FlowSurface.defaultCSP)
        XCTAssertEqual(config.userContentController.userScripts.count, 1)
        let script = config.userContentController.userScripts[0]
        XCTAssertEqual(script.injectionTime, .atDocumentEnd)
        XCTAssertTrue(script.isForMainFrameOnly)
    }

    @MainActor
    func testMessageDispatchDispatchesToCallbacks() {
        let surface = FlowSurface()
        var receivedProgress: Int?
        var receivedResource: Int?
        var receivedOffset: Int?
        var receivedFraction: Double?
        var receivedPage: Int?
        var receivedAction: Bool?
        var receivedColumn: Int?

        surface.onProgress = { receivedProgress = $0 }
        surface.onPosition = { resource, offset, fraction in
            receivedResource = resource
            receivedOffset = offset
            receivedFraction = fraction
        }
        surface.onPageInfo = { page, _, _, _ in receivedPage = page }
        surface.onPageAction = { receivedAction = $0 }
        surface.onPositionUpdate = { col, _ in receivedColumn = col }

        surface.didReceiveMessage(name: "progressHandler", body: 42)
        XCTAssertEqual(receivedProgress, 42)

        surface.didReceiveMessage(name: "positionHandler", body: ["resource": 1, "offset": 120, "fraction": 0.35])
        XCTAssertEqual(receivedResource, 1)
        XCTAssertEqual(receivedOffset, 120)
        XCTAssertEqual(receivedFraction, 0.35)

        let pageInfoJSON = "{\"page\":2,\"totalPages\":5,\"spineIndex\":1,\"spineCount\":3}"
        surface.didReceiveMessage(name: "pageInfoHandler", body: pageInfoJSON)
        XCTAssertEqual(receivedPage, 2)

        surface.didReceiveMessage(name: "pageAction", body: "{\"action\":\"nextSpineItem\"}")
        XCTAssertEqual(receivedAction, true)

        surface.didReceiveMessage(name: "positionUpdate", body: "{\"column\":3,\"totalColumns\":10}")
        XCTAssertEqual(receivedColumn, 3)
    }

    @MainActor
    func testContentJavaScriptIsDisabledAndClientWorldScriptRuns() throws {
        let surface = FlowSurface()
        let html = "<!doctype html><html><body><div id=\"content\">Hello</div><script>window.authorScriptRan=true;</script></body></html>"
        let dummy = EPUBPackage(
            rootFolder: FileManager.default.temporaryDirectory, spineURLs: [], title: "T", author: "A", coverURL: nil, manifest: [:], spine: [])
        surface.attach(package: dummy, html: html)

        let config = WKWebViewConfiguration()
        surface.install(into: config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)

        let loaded = expectation(description: "Flow document loaded")
        let watcher = FlowTestWatcher { loaded.fulfill() }
        webView.navigationDelegate = watcher

        guard let url = surface.documentURL else { return XCTFail("Missing URL") }
        webView.load(URLRequest(url: url))
        wait(for: [loaded], timeout: 5.0)

        verifyAuthorScriptDisabled(webView)
        verifyClientScriptEnabled(webView)
        _ = watcher
    }

    private func verifyAuthorScriptDisabled(_ webView: WKWebView) {
        let authorCheck = expectation(description: "Author script check")
        webView.evaluateJavaScript("Boolean(window.authorScriptRan)", in: nil, in: .page) { result in
            if case .success(let val) = result, let boolVal = val as? Bool {
                XCTAssertFalse(boolVal, "Author script should not execute when allowsContentJavaScript is false")
            }
            authorCheck.fulfill()
        }
        wait(for: [authorCheck], timeout: 5.0)
    }

    private func verifyClientScriptEnabled(_ webView: WKWebView) {
        let clientCheck = expectation(description: "Client script check")
        webView.evaluateJavaScript("typeof window.honeycrispPageInfo", in: nil, in: .defaultClient) { result in
            if case .success(let val) = result, let typeStr = val as? String {
                XCTAssertEqual(typeStr, "function", "honeycrispPageInfo should be defined in defaultClient world")
            } else {
                XCTFail("Failed to evaluate in defaultClient world")
            }
            clientCheck.fulfill()
        }
        wait(for: [clientCheck], timeout: 5.0)
    }

    @MainActor
    func testInstallScriptsConfiguresClientWorldForPagedMode() {
        let surface = FlowSurface()
        let config = WKWebViewConfiguration()
        surface.install(into: config)
        let controller = config.userContentController

        // Initial scroll mode
        XCTAssertEqual(surface.presentationMode, .scroll)
        XCTAssertEqual(controller.userScripts.count, 1)

        // Switch to paginated mode
        surface.installScripts(mode: .paginated, cols: .two, restore: .start, into: controller)
        XCTAssertEqual(surface.presentationMode, .paginated)
        XCTAssertEqual(controller.userScripts.count, 2)

        let baseScript = controller.userScripts[0].source
        XCTAssertTrue(baseScript.contains("window._qlPaginated = true;"))
        XCTAssertTrue(baseScript.contains("window.qlSetup"))

        let bootstrapScript = controller.userScripts[1].source
        XCTAssertTrue(bootstrapScript.contains("window.qlSetup(2)"))
        XCTAssertTrue(bootstrapScript.contains("window.qlScrollToColumn(0)"))
        XCTAssertTrue(bootstrapScript.contains("document.documentElement.style.visibility = 'visible'"))

        // Switch back to scroll mode
        surface.installScripts(mode: .scroll, into: controller)
        XCTAssertEqual(surface.presentationMode, .scroll)
        XCTAssertEqual(controller.userScripts.count, 1)
        XCTAssertFalse(controller.userScripts[0].source.contains("window._qlPaginated = true;"))
    }

    @MainActor
    func testFlowSurfaceDidFinishNavigationHandlesPagedModeOnly() {
        let surface = FlowSurface()
        let config = WKWebViewConfiguration()
        surface.install(into: config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        let engine = PaginationEngine(webView: webView, contentWorld: .defaultClient)

        // In scroll mode, returns false
        XCTAssertFalse(surface.didFinishNavigation(in: webView, paginationEngine: engine, colsPerScreen: .one))

        // In paginated mode, returns true
        surface.installScripts(mode: .paginated, cols: .two, restore: .start, into: config.userContentController)
        XCTAssertTrue(surface.didFinishNavigation(in: webView, paginationEngine: engine, colsPerScreen: .two))
    }

    @MainActor
    func testPagedDocumentLoadsAndExecutesBootstrapInClientWorld() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chURL = tempDir.appendingPathComponent("ch1.xhtml")
        try "<html><body><h1>Chapter 1</h1><p>Pagination test content with enough text.</p></body></html>".write(to: chURL, atomically: true, encoding: .utf8)
        let manifest = ["ch1.xhtml": EPUBManifestItem(id: "c1", href: "ch1.xhtml", mediaType: "application/xhtml+xml", properties: [], url: chURL)]
        let spine = [EPUBSpineItem(manifestID: "c1", url: chURL, isLinear: true)]
        let pkg = EPUBPackage(
            rootFolder: tempDir,
            spineURLs: [chURL],
            title: "Test",
            author: "Author",
            coverURL: nil,
            manifest: manifest,
            spine: spine
        )

        let surface = FlowSurface()
        let config = WKWebViewConfiguration()
        surface.install(into: config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), configuration: config)

        let colCSS = ":root { column-width: 280px; column-gap: 20px; }"
        let pagedHTML = try FlowDocumentBuilder.buildPagedDocument(
            resource: 0,
            package: pkg,
            columnCSS: colCSS
        )
        surface.attachPaged(package: pkg, html: pagedHTML)
        surface.installScripts(mode: .paginated, cols: .one, restore: .start, into: config.userContentController)

        let loaded = expectation(description: "Paged document loaded")
        let watcher = FlowTestWatcher { loaded.fulfill() }
        webView.navigationDelegate = watcher

        guard let url = surface.pagedDocumentURL else { return XCTFail("Missing pagedDocumentURL") }
        webView.load(URLRequest(url: url))
        wait(for: [loaded], timeout: 5.0)

        let engine = PaginationEngine(webView: webView, contentWorld: .defaultClient)
        XCTAssertTrue(surface.didFinishNavigation(in: webView, paginationEngine: engine, colsPerScreen: .one))

        verifyPagedClientScripts(in: webView)
        _ = watcher
    }

    private func verifyPagedClientScripts(in webView: WKWebView) {
        let paginatedFlagCheck = expectation(description: "Paginated flag check")
        webView.evaluateJavaScript("Boolean(window._qlPaginated)", in: nil, in: .defaultClient) { result in
            if case .success(let val) = result, let boolVal = val as? Bool {
                XCTAssertTrue(boolVal, "window._qlPaginated should be true in defaultClient")
            } else {
                XCTFail("Failed to read window._qlPaginated")
            }
            paginatedFlagCheck.fulfill()
        }
        wait(for: [paginatedFlagCheck], timeout: 5.0)

        let metricsCheck = expectation(description: "Pagination metrics check")
        webView.evaluateJavaScript("typeof window.qlPaginationMetrics", in: nil, in: .defaultClient) { result in
            if case .success(let val) = result, let typeStr = val as? String {
                XCTAssertEqual(typeStr, "function", "qlPaginationMetrics should be defined in defaultClient")
            } else {
                XCTFail("Failed to read qlPaginationMetrics")
            }
            metricsCheck.fulfill()
        }
        wait(for: [metricsCheck], timeout: 5.0)
    }
}

private final class FlowTestWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
