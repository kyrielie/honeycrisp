import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

final class FlowPositionTests: XCTestCase {
    @MainActor
    func testFlowSurfaceDispatchesResourceAndOffset() {
        let surface = FlowSurface()
        var reportedResource: Int?
        var reportedOffset: Int?
        var reportedFraction: Double?

        surface.onPosition = { resource, offset, fraction in
            reportedResource = resource
            reportedOffset = offset
            reportedFraction = fraction
        }

        let payload: [String: Any] = [
            "resource": 3,
            "offset": 240,
            "fraction": 0.65,
        ]
        surface.didReceiveMessage(name: "positionHandler", body: payload)

        XCTAssertEqual(reportedResource, 3)
        XCTAssertEqual(reportedOffset, 240)
        XCTAssertEqual(reportedFraction, 0.65)
    }

    @MainActor
    func testSectionRootedPositionReportsResourceAndLocalOffset() async throws {
        let webView = try await makeConfiguredFlowWebView()
        let initialRes = try await evalJS(webView, "honeycrispCurrentPosition();")
        let initialDict = try XCTUnwrap(initialRes as? [String: Any])

        XCTAssertEqual((initialDict["resource"] as? NSNumber)?.intValue, 0)
        let initialOffset = (initialDict["offset"] as? NSNumber)?.intValue ?? -1
        XCTAssertGreaterThanOrEqual(initialOffset, 0)

        _ = try await evalJS(webView, "honeycrispNavigateToSectionOffset(1, 20);")
        try await Task.sleep(nanoseconds: 100_000_000)

        let scrolledRes = try await evalJS(webView, "honeycrispCurrentPosition();")
        let scrolledDict = try XCTUnwrap(scrolledRes as? [String: Any])

        XCTAssertEqual((scrolledDict["resource"] as? NSNumber)?.intValue, 1)
        let offset = (scrolledDict["offset"] as? NSNumber)?.intValue ?? -1
        XCTAssertGreaterThanOrEqual(offset, 0)
        XCTAssertLessThanOrEqual(offset, 60)
    }

    @MainActor
    func testNavigateToSectionOffsetZeroLandsOnStart() async throws {
        let webView = try await makeConfiguredFlowWebView()
        _ = try await evalJS(webView, "honeycrispNavigateToSectionOffset(1, 0);")
        try await Task.sleep(nanoseconds: 100_000_000)

        let posRes = try await evalJS(webView, "honeycrispCurrentPosition();")
        let posDict = try XCTUnwrap(posRes as? [String: Any])

        XCTAssertEqual((posDict["resource"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((posDict["offset"] as? NSNumber)?.intValue, 0)
    }

    @MainActor
    private func evalJS(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let val):
                    continuation.resume(returning: val)
                case .failure(let err):
                    continuation.resume(throwing: err)
                }
            }
        }
    }

    @MainActor
    private func makeConfiguredFlowWebView() async throws -> WKWebView {
        let surface = FlowSurface()
        let html = """
        <!doctype html>
        <html>
        <head>
          <style>
            body { margin: 0; padding: 0; }
            section.hc-chapter { min-height: 800px; padding: 40px; box-sizing: border-box; }
            p { font-size: 16px; line-height: 24px; margin: 20px 0; }
          </style>
        </head>
        <body>
          <section class="hc-chapter" id="hc-r0" data-resource="0"><p id="p0">Zero Chapter Alpha. Text in section zero continues here.</p>
            <p>More text in section zero spanning multiple paragraphs.</p></section>
          <section class="hc-chapter" id="hc-r1" data-resource="1"><p id="p1">One Chapter Beta. Text in section one begins here.</p>
            <p>Second paragraph in section one with additional content.</p></section>
        </body>
        </html>
        """
        let dummy = EPUBPackage(
            rootFolder: FileManager.default.temporaryDirectory,
            spineURLs: [],
            title: "Test",
            author: "Author",
            coverURL: nil,
            manifest: [:],
            spine: []
        )
        surface.attach(package: dummy, html: html)

        let config = WKWebViewConfiguration()
        surface.install(into: config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), configuration: config)

        let loaded = expectation(description: "Flow HTML loaded")
        let watcher = FlowPositionWatcher { loaded.fulfill() }
        webView.navigationDelegate = watcher

        guard let url = surface.documentURL else { throw XCTSkip("Missing document URL") }
        webView.load(URLRequest(url: url))
        await fulfillment(of: [loaded], timeout: 5.0)
        _ = watcher
        return webView
    }
}

private final class FlowPositionWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
