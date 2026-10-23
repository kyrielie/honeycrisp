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
        XCTAssertFalse(surface.managesPagedChapter)
        XCTAssertFalse(surface.handlesReadingModeToggle)
        XCTAssertFalse(surface.handlesStructuralReload)
        XCTAssertFalse(surface.handlesPaginatedResize)
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
        var receivedOffset: Int?
        var receivedFraction: Double?
        var receivedPage: Int?
        var receivedAction: Bool?
        var receivedColumn: Int?

        surface.onProgress = { receivedProgress = $0 }
        surface.onPosition = { receivedOffset = $0; receivedFraction = $1 }
        surface.onPageInfo = { page, _, _, _ in receivedPage = page }
        surface.onPageAction = { receivedAction = $0 }
        surface.onPositionUpdate = { col, _ in receivedColumn = col }

        surface.didReceiveMessage(name: "progressHandler", body: 42)
        XCTAssertEqual(receivedProgress, 42)

        surface.didReceiveMessage(name: "positionHandler", body: ["offset": 120, "fraction": 0.35])
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
}

private final class FlowTestWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
