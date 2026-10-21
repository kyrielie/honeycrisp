import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Shared harness for chapter host tests that need a mounted window (roadmap M3, passes 7 and 8): builds a
/// small synthetic book in a temp directory, configures a web view the way `ReaderViewController.loadView`
/// does under the flag (own content controller, then `ChapterHostSurface.install`), mounts the window
/// around a chapter and waits for the shell to finish loading.
///
/// Fixture: chapter `i` has `i * 15 + 5` plain paragraphs after `<p id="probe">`, a heading
/// `<h2>Chapter i+1</h2>` and a linked book stylesheet that sets `p { color: #cc0000; }` and
/// `body { font-size: 12px; }` (rules the user layer must beat). `chapterXHTML` replaces a chapter's bytes.
@MainActor
final class ChapterHostWindowHarness {
    let root: URL
    let package: EPUBPackage
    let surface: ChapterHostSurface
    let webView: WKWebView
    private let navigation: HarnessNavigationDelegate

    /// Main-frame commits so far. Chapter iframes do not count, so a value that stays put proves the
    /// shell was not navigated again.
    var commitCount: Int { navigation.commits }

    private init(
        root: URL, package: EPUBPackage, surface: ChapterHostSurface, webView: WKWebView,
        navigation: HarnessNavigationDelegate
    ) {
        self.root = root
        self.package = package
        self.surface = surface
        self.webView = webView
        self.navigation = navigation
    }

    static func make(
        in testCase: XCTestCase, chapters: Int = 5, around index: Int = 2,
        cosmetics: ReaderCosmeticSettings = .chapterHostFixture, chapterXHTML: ((Int) -> String)? = nil
    ) async throws -> ChapterHostWindowHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispHostHarness-\(UUID().uuidString)", isDirectory: true)
        let package = try writeBook(chapters: chapters, to: root, chapterXHTML: chapterXHTML)
        let surface = ChapterHostSurface()
        surface.attach(package: package, cosmetics: cosmetics)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        surface.install(into: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let finished = testCase.expectation(description: "host window loads")
        let navigation = HarnessNavigationDelegate { finished.fulfill() }
        webView.navigationDelegate = navigation
        try surface.loadWindow(around: index, in: package, into: webView)
        await testCase.fulfillment(of: [finished], timeout: 30)
        XCTAssertNil(navigation.error)
        return ChapterHostWindowHarness(
            root: root, package: package, surface: surface, webView: webView, navigation: navigation)
    }

    func tearDown() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        try? FileManager.default.removeItem(at: root)
    }

    /// Evaluates `script` in the page world (the same world the other host tests read the DOM in) and
    /// returns the result as a string.
    func evaluate(_ script: String) async throws -> String {
        let value = try await webView.evaluateJavaScript(script)
        return String(describing: try XCTUnwrap(value))
    }

    /// Decodes a JSON array of objects returned by `script`.
    func evaluateJSONArray(_ script: String) async throws -> [[String: Any]] {
        let json = try await evaluate(script)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private static func writeBook(
        chapters: Int, to root: URL, chapterXHTML: ((Int) -> String)?
    ) throws -> EPUBPackage {
        let text = root.appendingPathComponent("Text", isDirectory: true)
        let styles = root.appendingPathComponent("Styles", isDirectory: true)
        for directory in [text, styles] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("p { color: #cc0000; } body { font-size: 12px; }".utf8).write(to: styles.appendingPathComponent("book.css"))
        var urls: [URL] = []
        for index in 0..<chapters {
            let paragraphs = (0..<(index * 15 + 5)).map { "<p>Paragraph \($0) of chapter \(index).</p>" }.joined(separator: "\n")
            let xhtml = chapterXHTML?(index) ?? """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c\(index)</title>
                <link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
                <body><h2>Chapter \(index + 1)</h2><p id="probe">probe</p>
                \(paragraphs)
                </body></html>
                """
            let url = text.appendingPathComponent("Chapter \(index + 1).xhtml")
            try Data(xhtml.utf8).write(to: url)
            urls.append(url)
        }
        return EPUBPackage(rootFolder: root, spineURLs: urls, title: "t", author: "a", coverURL: nil, language: "en")
    }
}

private final class HarnessNavigationDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void
    private var finished = false
    private(set) var commits = 0
    private(set) var error: Error?

    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    private func finish(_ failure: Error?) {
        guard !finished else { return }
        finished = true
        error = failure
        onFinish()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { commits += 1 }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { finish(error) }
}
