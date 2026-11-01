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

    /// Verifies that speech highlight boxes get a visible background-color in the
    /// presence of the full readerCSS (including the universal background-color:transparent rule).
    @MainActor
    func testSpeechHighlightBoxesHaveVisibleBackgroundWithReaderCSS() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class=\"hc-chapter\" id=\"hc-r0\" data-resource=\"0\">
            <p>Hello world. Second sentence.</p>
            </section>
            """, includeReaderCSS: true)

        _ = try await evalJS(webView, "window.honeycrispSpeechHighlight(0, 0, 12, 0, 5, 0);")

        let sentenceBg = try await evalJS(webView, """
            (() => {
                const box = document.querySelector('.hc-sp-s');
                if (!box) return null;
                return window.getComputedStyle(box).backgroundColor;
            })();
            """) as? String
        let sentenceBgValue = try XCTUnwrap(sentenceBg, "No .hc-sp-s box found")
        XCTAssertFalse(sentenceBgValue.isEmpty, "computed backgroundColor is empty")
        // transparent means the fix failed
        XCTAssertFalse(
            sentenceBgValue == "rgba(0, 0, 0, 0)" || sentenceBgValue == "transparent",
            ".hc-sp-s has transparent background; expected speech color. Got: \(sentenceBgValue)"
        )

        let wordBg = try await evalJS(webView, """
            (() => {
                const box = document.querySelector('.hc-sp-w');
                if (!box) return null;
                return window.getComputedStyle(box).backgroundColor;
            })();
            """) as? String
        let wordBgValue = try XCTUnwrap(wordBg, "No .hc-sp-w box found")
        XCTAssertFalse(
            wordBgValue == "rgba(0, 0, 0, 0)" || wordBgValue == "transparent",
            ".hc-sp-w has transparent background; expected speech color. Got: \(wordBgValue)"
        )
    }

    /// Verifies that search hit marks get a visible background-color in the
    /// presence of the full readerCSS universal background-color:transparent rule.
    @MainActor
    func testSearchHitMarksHaveVisibleBackgroundWithReaderCSS() async throws {
        let webView = try await makeConfiguredFlowWebView(bodyHTML: """
            <section class=\"hc-chapter\" id=\"hc-r0\" data-resource=\"0\">
            <p><mark class=\"ql-hit\">word</mark> rest of sentence.</p>
            </section>
            """, includeReaderCSS: true)

        let hitBg = try await evalJS(webView, """
            (() => {
                const mark = document.querySelector('mark.ql-hit');
                if (!mark) return null;
                return window.getComputedStyle(mark).backgroundColor;
            })();
            """) as? String
        let hitBgValue = try XCTUnwrap(hitBg, "No mark.ql-hit element found")
        XCTAssertFalse(
            hitBgValue == "rgba(0, 0, 0, 0)" || hitBgValue == "transparent",
            "mark.ql-hit has transparent background; expected hit color. Got: \(hitBgValue)"
        )
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
    private func makeConfiguredFlowWebView(bodyHTML: String, includeReaderCSS: Bool = false) async throws -> WKWebView {
        let surface = FlowSurface()
        let readerCSSBlock = includeReaderCSS
            ? "<style>\(ReaderStyles.readerCSS)</style>"
            : ""
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\">
          <style id=\"honeycrisp-vars\">:root { --reader-speech-sentence: rgba(0, 104, 218, 0.2); --reader-speech-word: rgba(0, 104, 218, 0.4); --reader-hit-bg: #FFEE58; --reader-hit-text: #000000; --reader-hit-active-bg: Highlight; --reader-hit-active-text: HighlightText; }</style>
          \(readerCSSBlock)
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
