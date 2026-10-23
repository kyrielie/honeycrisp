import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

final class FlowBookmarkTests: XCTestCase {

    @MainActor
    func testCurrentChapterCharacterOffsetReturnsLocalSectionOffset() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class="hc-chapter" id="hc-r0" data-resource="0">
              <p>Short preamble.</p>
            </section>
            <section class="hc-chapter" id="hc-r1" data-resource="1">
              <p>Chapter one body text with multiple words for measuring character offset.</p>
            </section>
            """)

        let ch0Offset = try await evalJS(webView, "window.honeycrispCurrentChapterCharacterOffset(0);") as? Int
        let ch1Offset = try await evalJS(webView, "window.honeycrispCurrentChapterCharacterOffset(1);") as? Int

        XCTAssertNotNil(ch0Offset)
        XCTAssertNotNil(ch1Offset)
        // Chapter 1 offset must be relative to its section, bounded by section text length
        let ch1Len = "Chapter one body text with multiple words for measuring character offset.".count
        XCTAssertTrue((ch1Offset ?? 0) <= ch1Len + 20)
    }

    @MainActor
    func testVisibleCharacterRangeOnSection() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class="hc-chapter" id="hc-r0" data-resource="0">
              <p>First section visible content.</p>
            </section>
            """)

        let rangeResult = try await evalJS(webView, "window.honeycrispVisibleCharacterRange(true, 0);")
        let bounds = rangeResult as? [Int]
        XCTAssertNotNil(bounds)
        XCTAssertEqual(bounds?.count, 2)
        if let bounds, bounds.count == 2 {
            XCTAssertTrue(bounds[0] <= bounds[1])
        }
    }

    @MainActor
    func testNavigateToChapterOffsetExecutesWithoutError() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class="hc-chapter" id="hc-r0" data-resource="0">
              <p>First section content.</p>
            </section>
            <section class="hc-chapter" id="hc-r1" data-resource="1">
              <p>Second section content with enough text to scroll.</p>
            </section>
            """)

        _ = try await evalJS(webView, "window.honeycrispNavigateToChapterOffset(1, 10);")
        // Verify script did not throw and page is intact
        let activeEl = try await evalJS(webView, "document.getElementById('hc-r1') !== null;") as? Bool
        XCTAssertEqual(activeEl, true)
    }

    func testBookmarkMatchingWithinVisibleRange() {
        let bookURL = URL(fileURLWithPath: "/tmp/fake-bookmark-book.epub")
        let b1 = ReadingBookmark(bookURL: bookURL, label: "P1", spineIndex: 0, characterOffset: 25)
        let b2 = ReadingBookmark(bookURL: bookURL, label: "P2", spineIndex: 0, characterOffset: 150)
        let b3 = ReadingBookmark(bookURL: bookURL, label: "Ch2", spineIndex: 1, characterOffset: 25)

        let visibleRange = 0...50

        // Test spineIndex 0 matching
        let inSection0 = [b1, b2, b3].filter { $0.spineIndex == 0 && visibleRange.contains($0.characterOffset) }
        XCTAssertEqual(inSection0.count, 1)
        XCTAssertEqual(inSection0.first?.id, b1.id)

        // b3 is in spineIndex 1, so it shouldn't match spineIndex 0 even with the same offset
        XCTAssertFalse(inSection0.contains { $0.id == b3.id })
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
        let watcher = FlowBookmarkWatcher { loaded.fulfill() }
        webView.navigationDelegate = watcher

        _ = webView.load(
            URLRequest(url: URL(string: "honeycrisp-epub://book/__app/flow.html")!)
        )
        await fulfillment(of: [loaded], timeout: 5.0)
        return webView
    }
}

private final class FlowBookmarkWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
