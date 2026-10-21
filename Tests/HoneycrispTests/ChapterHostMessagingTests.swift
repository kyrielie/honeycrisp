import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 4, assumption V1: a client-world message handler receives posts while content
/// JavaScript is off, and the host script uses one to report the reading position.
@MainActor
final class ChapterHostMessagingTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// Replaces the record-only check in `ChapterHostSpikeTests` (decision N4): fails when the post is lost.
    func testClientWorldMessageHandlerReceivesPostWithContentJavaScriptOff() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let received = expectation(description: "client-world handler receives a post")
        let handler = ProbeHandler { received.fulfill() }
        configuration.userContentController.add(handler, contentWorld: .defaultClient, name: "probe")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loaded = expectation(description: "loads")
        let delegate = LoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<html><body>x</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await webView.callAsyncJavaScript(
            "window.webkit.messageHandlers.probe.postMessage('hello'); return 1;", arguments: [:], in: nil,
            contentWorld: .defaultClient)
        await fulfillment(of: [received], timeout: 5)
    }

    private func mount() async throws -> (ChapterHostWindowHarness, Recorder) {
        let made = try await ChapterHostWindowHarness.make(in: self, chapters: 5, around: 2)
        harness = made
        let recorder = Recorder()
        made.surface.onPositionChange = { position, page, pages in recorder.posts.append((position, page, pages)) }
        return (made, recorder)
    }

    private func run(_ harness: ChapterHostWindowHarness, _ body: String) async throws {
        _ = try await harness.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    func testScrollPostsPositionWithResourceOffsetAndChapterPage() async throws {
        let (harness, recorder) = try await mount()
        for _ in 0..<3 {
            try await run(harness, "window.scrollBy(0, 480); return 1;")
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        XCTAssertFalse(recorder.posts.isEmpty, "scrolling posted a position")
        var last = (resource: -1, offset: -1)
        for post in recorder.posts {
            XCTAssertTrue((1...3).contains(post.0.resource), "a mounted chapter: \(post.0)")
            XCTAssertTrue((1...post.2).contains(post.1), "page \(post.1) within 1...\(post.2)")
            XCTAssertTrue(
                post.0.resource > last.resource || (post.0.resource == last.resource && post.0.offset >= last.offset),
                "monotonic while scrolling down: \(last) then \(post.0)")
            last = (post.0.resource, post.0.offset)
        }
    }

    func testPostsAreDebounced() async throws {
        let (harness, recorder) = try await mount()
        try await Task.sleep(nanoseconds: 300_000_000)
        recorder.posts.removeAll()
        try await run(harness, "for (var i = 0; i < 50; i++) { window.scrollBy(0, 2); window.dispatchEvent(new Event('scroll')); } return 1;")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertLessThanOrEqual(recorder.posts.count, 2, "50 scroll events inside 100 ms post at most twice")
        XCTAssertGreaterThanOrEqual(recorder.posts.count, 1)
    }

    func testMalformedPositionMessagesAreIgnored() async throws {
        let (harness, recorder) = try await mount()
        try await Task.sleep(nanoseconds: 300_000_000)
        recorder.posts.removeAll()
        try await run(
            harness,
            "window.webkit.messageHandlers.hostPosition.postMessage('{\"resource\":-1}'); "
            + "window.webkit.messageHandlers.hostPosition.postMessage(5); return 1;")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(recorder.posts.isEmpty)
    }
}

private final class Recorder {
    var posts: [(ChapterHostSurface.Position, Int, Int)] = []
}

private final class ProbeHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: () -> Void
    init(_ onMessage: @escaping () -> Void) { self.onMessage = onMessage }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { onMessage() }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void
    init(_ onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
