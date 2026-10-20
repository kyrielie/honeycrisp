import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// SPIKE (roadmap M3): measures WebKit behavior through `EPUBResourceSchemeHandler` on synthetic
/// fixtures. Each test records what it observed as a kept attachment, so read the test report, not
/// only pass or fail. Record the outcomes in docs/ROADMAP.md section 6, with the macOS and Xcode
/// versions, then delete this file or promote the cases per the M3 decision (FRAMEWORK section 6.4).
/// macOS 13 behavior is not measured by running this on a newer macOS.
@MainActor
final class ChapterHostSpikeTests: XCTestCase {
    private var root: URL!
    private var handler: EPUBResourceSchemeHandler!
    private var loadDelegate: SpikeLoadDelegate!
    private var messageHandler: SpikeMessageHandler!

    // 1x1 RGB PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    private static let chapter = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>t</title>
        <link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
        <body><p id="p1">Before <a id="x"/>AFTER_ANCHOR text</p>
        <p class="i" id="it">italic</p><img id="pic" src="Images/pic.png" alt=""/>
        <script>window.__author = 1;</script></body></html>
        """

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispSpike-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("Text/Images"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Styles"), withIntermediateDirectories: true)
        try Data(Self.chapter.utf8).write(to: root.appendingPathComponent("Text/ch1.xhtml"))
        try Self.png.write(to: root.appendingPathComponent("Text/Images/pic.png"))
        try Data(".i { font-style: italic; }".utf8).write(to: root.appendingPathComponent("Styles/book.css"))
        try Data("<html><body><p>unclosed <br></p></body></html>".utf8)
            .write(to: root.appendingPathComponent("Text/bad.html"))
        try Data(count: 20_000_000).write(to: root.appendingPathComponent("Text/big.xhtml"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: C5 and C4 host behavior

    func testSelfClosedAnchorDoesNotSwallowContent() async throws {
        let (webView, error) = try await load("Text/ch1.xhtml")
        XCTAssertNil(error)

        let length = try await webView.evaluateJavaScript("document.getElementById('x').textContent.length")
        let contentType = try await webView.evaluateJavaScript("document.contentType")
        record("document.contentType", contentType)
        XCTAssertEqual((length as? NSNumber)?.intValue, 0)
    }

    func testRelativeImageResolvesWithoutRewriting() async throws {
        let (webView, error) = try await load("Text/ch1.xhtml")
        XCTAssertNil(error)

        let width = try await webView.callAsyncJavaScript(
            """
            const image = document.getElementById('pic');
            if (image.complete) { return image.naturalWidth; }
            return await new Promise(resolve => image.addEventListener('load', () => resolve(image.naturalWidth)));
            """,
            contentWorld: .page)
        XCTAssertEqual((width as? NSNumber)?.intValue, 1)
    }

    func testClassOnlyItalicFromBookStylesheetApplies() async throws {
        let (webView, error) = try await load("Text/ch1.xhtml")
        XCTAssertNil(error)

        let style = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('it')).fontStyle")
        XCTAssertEqual(style as? String, "italic")
    }

    // MARK: R10 / C6 content isolation

    func testAuthorScriptRunsWhenJavaScriptAllowed() async throws {
        let (webView, error) = try await load("Text/ch1.xhtml", allowsContentJavaScript: true)
        XCTAssertNil(error)

        let type = try await webView.evaluateJavaScript("typeof window.__author")
        XCTAssertEqual(type as? String, "number", "positive control: the author script must be observable")
    }

    func testAuthorScriptDoesNotRunWhenContentJavaScriptIsDisabled() async throws {
        let (webView, error) = try await load("Text/ch1.xhtml", allowsContentJavaScript: false)
        XCTAssertNil(error)

        let type = try? await webView.evaluateJavaScript("typeof window.__author")
        record("typeof window.__author (page world, content JS off)", type ?? "evaluateJavaScript failed")
        XCTAssertNotEqual(type as? String, "number")
    }

    func testClientWorldMechanismsWhenContentJavaScriptIsDisabled() async throws {
        let script = WKUserScript(
            source: "window.__clientScript = 'ran';", injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .defaultClient)
        let (webView, error) = try await load(
            "Text/ch1.xhtml", allowsContentJavaScript: false,
            configure: { configuration in
                configuration.userContentController.addUserScript(script)
                configuration.userContentController.add(self.messageHandler, contentWorld: .defaultClient, name: "spike")
            })
        XCTAssertNil(error)

        let userScript = try? await webView.callAsyncJavaScript(
            "return typeof window.__clientScript", contentWorld: .defaultClient)
        record("WKUserScript in .defaultClient", userScript ?? "failed")

        let direct = try? await webView.callAsyncJavaScript("return 40 + 2", contentWorld: .defaultClient)
        record("callAsyncJavaScript in .defaultClient", direct ?? "failed")

        let received = expectation(description: "client-world message handler receives a post")
        messageHandler.onMessage = { received.fulfill() }
        _ = try? await webView.callAsyncJavaScript(
            "window.webkit.messageHandlers.spike.postMessage('hello'); return 1;", contentWorld: .defaultClient)
        let outcome = await XCTWaiter().fulfillment(of: [received], timeout: 3)
        record("message handler in .defaultClient", outcome == .completed ? "received" : "not received")
    }

    func testContentSecurityPolicyHeaderFromSchemeHandler() async throws {
        let (webView, error) = try await load(
            "Text/ch1.xhtml", allowsContentJavaScript: true,
            headers: ["Content-Security-Policy": "script-src 'none'"])
        XCTAssertNil(error)

        let type = try await webView.evaluateJavaScript("typeof window.__author")
        record("typeof window.__author with CSP script-src 'none'", type)
    }

    // MARK: Handler edge cases

    func testNonWellFormedHtmlServedAsXml() async throws {
        let (webView, error) = try await load("Text/bad.html")
        record("navigation error", error.map { "\($0)" } ?? "none")

        let state = try? await webView.evaluateJavaScript(
            "JSON.stringify({ parserError: !!document.querySelector('parsererror'), text: document.body ? document.body.textContent : null })")
        record(".html served as application/xhtml+xml", state ?? "evaluateJavaScript failed")
    }

    func testStoppingALoadMidFlightDoesNotCrash() async throws {
        let configuration = makeConfiguration(allowsContentJavaScript: true, headers: [:], configure: { _ in })
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.load(URLRequest(url: URL(string: "honeycrisp-epub://book/Text/big.xhtml")!))
        webView.stopLoading()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await webView.evaluateJavaScript("1 + 1")
        XCTAssertEqual((result as? NSNumber)?.intValue, 2)
    }

    // MARK: Helpers

    private func makeConfiguration(
        allowsContentJavaScript: Bool, headers: [String: String], configure: (WKWebViewConfiguration) -> Void
    ) -> WKWebViewConfiguration {
        handler = EPUBResourceSchemeHandler(rootFolder: root)
        handler.responseHeaders = headers
        messageHandler = messageHandler ?? SpikeMessageHandler()
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsContentJavaScript
        configuration.setURLSchemeHandler(handler, forURLScheme: EPUBResourceSchemeHandler.scheme)
        configure(configuration)
        return configuration
    }

    private func load(
        _ path: String, allowsContentJavaScript: Bool = true, headers: [String: String] = [:],
        configure: (WKWebViewConfiguration) -> Void = { _ in }
    ) async throws -> (WKWebView, Error?) {
        messageHandler = SpikeMessageHandler()
        let configuration = makeConfiguration(
            allowsContentJavaScript: allowsContentJavaScript, headers: headers, configure: configure)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let finished = expectation(description: "navigation to \(path) finishes")
        var outcome: Error?
        loadDelegate = SpikeLoadDelegate { error in
            outcome = error
            finished.fulfill()
        }
        webView.navigationDelegate = loadDelegate
        webView.load(URLRequest(url: URL(string: "honeycrisp-epub://book/\(path)")!))
        await fulfillment(of: [finished], timeout: 10)
        return (webView, outcome)
    }

    private func record(_ name: String, _ value: Any?) {
        let attachment = XCTAttachment(string: "\(name): \(value.map { "\($0)" } ?? "nil")")
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class SpikeLoadDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: (Error?) -> Void
    private var finished = false

    init(onFinish: @escaping (Error?) -> Void) { self.onFinish = onFinish }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        onFinish(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { finish(error) }
}

private final class SpikeMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: () -> Void = {}

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage()
    }
}
