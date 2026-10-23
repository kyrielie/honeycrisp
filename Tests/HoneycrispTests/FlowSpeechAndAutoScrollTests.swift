import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

final class FlowSpeechAndAutoScrollTests: XCTestCase {

    @MainActor
    func testSpeechScriptSkipsHiddenElementsAndExtractsVisibleText() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class="hc-chapter" id="hc-r0" data-resource="0">
              <h1>Chapter One</h1>
              <p>Visible intro text.</p>
              <div hidden><p>Hidden text that should not be read</p></div>
              <div aria-hidden="true"><p>Aria hidden text</p></div>
              <p>Visible concluding paragraph.</p>
            </section>
            <section class="hc-chapter" id="hc-r1" data-resource="1">
              <h1>Chapter Two</h1>
              <p>Second chapter text.</p>
            </section>
            """)

        let ch0Speech = try await evalJS(webView, "window.honeycrispCurrentSpeechText(0);") as? String
        let unwrappedCh0 = try XCTUnwrap(ch0Speech)
        XCTAssertTrue(unwrappedCh0.contains("Chapter One"))
        XCTAssertTrue(unwrappedCh0.contains("Visible intro text."))
        XCTAssertTrue(unwrappedCh0.contains("Visible concluding paragraph."))
        XCTAssertFalse(unwrappedCh0.contains("Hidden text"))
        XCTAssertFalse(unwrappedCh0.contains("Aria hidden text"))

        let ch1Speech = try await evalJS(webView, "window.honeycrispCurrentSpeechText(1);") as? String
        let unwrappedCh1 = try XCTUnwrap(ch1Speech)
        XCTAssertTrue(unwrappedCh1.contains("Second chapter text."))
    }

    @MainActor
    func testAutoScrollListenerClearsFrameOnInteraction() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class="hc-chapter" id="hc-r0" data-resource="0">
              <p>Scroll content.</p>
            </section>
            """)

        // Set dummy animation frame id
        _ = try await evalJS(webView, "window.honeycrispAutoScrollFrame = 12345;")
        let beforeVal = try await evalJS(webView, "window.honeycrispAutoScrollFrame;") as? Int
        XCTAssertEqual(beforeVal, 12345)

        // Dispatch simulated wheel interaction
        _ = try await evalJS(webView, "window.dispatchEvent(new Event('wheel'));")
        let afterVal = try await evalJS(webView, "window.honeycrispAutoScrollFrame;")
        XCTAssertTrue(afterVal is NSNull || afterVal == nil)
    }

    @MainActor
    private func evalJS(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let val): continuation.resume(returning: val)
                case .failure(let err): continuation.resume(throwing: err)
                }
            }
        }
    }

    @MainActor
    private func makeConfiguredFlowWebView(bodyHTML: String) async throws -> WKWebView {
        let surface = FlowSurface()
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style id="honeycrisp-vars">:root { --hc-font-size: 16px; }</style>
        </head>
        <body>
          \(bodyHTML)
        </body>
        </html>
        """
        let dummy = EPUBPackage(
            rootFolder: URL(fileURLWithPath: "/tmp/fake-flow-book"),
            spineURLs: [],
            title: "Test",
            author: "",
            coverURL: nil,
            manifest: [:],
            spine: []
        )
        surface.attach(package: dummy, html: html)

        let config = WKWebViewConfiguration()
        surface.install(into: config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), configuration: config)

        let loaded = expectation(description: "Flow HTML loaded")
        let watcher = FlowSpeechWatcher { loaded.fulfill() }
        webView.navigationDelegate = watcher

        _ = webView.load(
            URLRequest(url: URL(string: "honeycrisp-epub://book/__app/flow.html")!)
        )
        await fulfillment(of: [loaded], timeout: 5.0)
        return webView
    }
}

private final class FlowSpeechWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
