//
//  FlowSpeechHighlightTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

final class FlowSpeechHighlightTests: XCTestCase {

    @MainActor
    func testHighlightTextsMatchSwiftSpaceOffsets() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class=\"hc-chapter\" id=\"hc-r0\" data-resource=\"0\">
            <p>Hello world. Second sentence.</p>
            </section>
            """)

        // "Hello world." is 0..<12, "Hello" is 0..<5
        let res = try await evalJS(
            webView,
            "window.honeycrispSpeechHighlight(0, 0, 12, 0, 5, 0);"
        ) as? [String: Any]

        let dict = try XCTUnwrap(res)
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["sentenceText"] as? String, "Hello world.")
        XCTAssertEqual(dict["wordText"] as? String, "Hello")

        // Overlay element exists in documentElement
        let inDocEl = try await evalJS(
            webView,
            "document.getElementById('hc-speech-hl').parentNode === document.documentElement;"
        ) as? Bool
        XCTAssertEqual(inDocEl, true)
    }

    @MainActor
    func testClearRemovesBoxes() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class=\"hc-chapter\" id=\"hc-r0\" data-resource=\"0\">
            <p>Some text.</p>
            </section>
            """)

        _ = try await evalJS(webView, "window.honeycrispSpeechHighlight(0, 0, 9, 0, 4, 0);")
        let boxCountBefore = try await evalJS(
            webView,
            "document.querySelectorAll('.hc-sp-s, .hc-sp-w').length;"
        ) as? Int
        XCTAssertGreaterThan(boxCountBefore ?? 0, 0)

        _ = try await evalJS(webView, "window.honeycrispSpeechClear();")
        let boxCountAfter = try await evalJS(
            webView,
            "document.querySelectorAll('.hc-sp-s, .hc-sp-w').length;"
        ) as? Int
        XCTAssertEqual(boxCountAfter, 0)
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
          <meta charset=\"utf-8\">
          <style id=\"honeycrisp-vars\">:root { --reader-speech-sentence: rgba(0, 104, 218, 0.2); --reader-speech-word: rgba(0, 104, 218, 0.4); }</style>
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
        let watcher = FlowHighlightWatcher { loaded.fulfill() }
        webView.navigationDelegate = watcher

        _ = webView.load(
            URLRequest(url: URL(string: "honeycrisp-epub://book/__app/flow.html")!)
        )
        await fulfillment(of: [loaded], timeout: 5.0)
        return webView
    }
}

private final class FlowHighlightWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
