import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

@MainActor
final class ChapterHostSurfaceTests: XCTestCase {
    private var root: URL!
    private var delegate: SurfaceLoadDelegate?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispSurface-\(UUID().uuidString)", isDirectory: true)
        for directory in ["Text/Images", "Styles"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: Pure

    func testFlagIsOnlyEnabledByExactlyOne() {
        let key = ChapterHostFlag.environmentKey
        XCTAssertFalse(ChapterHostFlag.isEnabled(environment: [:]))
        XCTAssertTrue(ChapterHostFlag.isEnabled(environment: [key: "1"]))
        for other in ["0", "true", "yes", "", "11"] {
            XCTAssertFalse(ChapterHostFlag.isEnabled(environment: [key: other]), other)
        }
    }

    func testChapterURLEncodesSpacesAndNestedPaths() {
        let url = ChapterHostSurface.chapterURL(for: root.appendingPathComponent("Text/Chapter 2.xhtml"), root: root)
        XCTAssertEqual(url?.absoluteString, "honeycrisp-epub://book/Text/Chapter%202.xhtml")
    }

    func testChapterURLEncodesQueryAndFragmentCharactersInNames() {
        let url = ChapterHostSurface.chapterURL(for: root.appendingPathComponent("Text/a#b?c.xhtml"), root: root)
        XCTAssertEqual(url?.absoluteString, "honeycrisp-epub://book/Text/a%23b%3Fc.xhtml")
    }

    func testChapterURLRejectsResourceOutsideRootAndTheRootItself() {
        let outside = root.deletingLastPathComponent().appendingPathComponent("elsewhere.xhtml")
        XCTAssertNil(ChapterHostSurface.chapterURL(for: outside, root: root))
        XCTAssertNil(ChapterHostSurface.chapterURL(for: root, root: root))
        let sibling = URL(fileURLWithPath: root.path + "-other/Text/a.xhtml")
        XCTAssertNil(ChapterHostSurface.chapterURL(for: sibling, root: root), "a shared name prefix is not containment")
    }

    func testChapterURLResolvesASymlinkedRoot() {
        let resolvedRoot = root.resolvingSymlinksInPath()
        let url = ChapterHostSurface.chapterURL(for: resolvedRoot.appendingPathComponent("Text/a.xhtml"), root: root)
        XCTAssertEqual(url?.absoluteString, "honeycrisp-epub://book/Text/a.xhtml")
    }

    func testNavigationIsAllowedOnlyForTheAppSchemeAndAboutBlank() {
        let allowed = ["honeycrisp-epub://book/Text/a.xhtml", "about:blank"]
        let denied = [
            "https://example.com/", "http://example.com/", "file:///etc/passwd", "data:text/html,hi",
            "javascript:alert(1)", "honeycrisp-other://book/a",
        ]
        for string in allowed { XCTAssertTrue(ChapterHostSurface.allowsNavigation(to: URL(string: string)), string) }
        for string in denied { XCTAssertFalse(ChapterHostSurface.allowsNavigation(to: URL(string: string)), string) }
        XCTAssertFalse(ChapterHostSurface.allowsNavigation(to: nil))
    }

    func testSpikeErrorsDescribeThemselves() {
        XCTAssertFalse(ChapterHostSurface.SpikeError.pagedModeUnsupported.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(ChapterHostSurface.SpikeError.chapterUnavailable(2).errorDescription?.contains("3") ?? false)
    }

    // MARK: Configuration

    func testInstallDisablesContentJavaScriptAndRegistersTheSchemeHandler() {
        let surface = ChapterHostSurface()
        let configuration = WKWebViewConfiguration()
        surface.install(into: configuration)
        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let registered = configuration.urlSchemeHandler(forURLScheme: EPUBResourceSchemeHandler.scheme)
        XCTAssertTrue((registered as AnyObject) === surface.schemeHandler)
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1, "the sizing script is installed")
    }

    func testAttachInstallsTheStylesheetAndTheMarkupTransform() throws {
        let surface = ChapterHostSurface()
        let package = try makePackage()
        surface.attach(package: package, cosmetics: .chapterHostFixture)
        XCTAssertEqual(
            surface.schemeHandler.rootFolder.path, root.resolvingSymlinksInPath().standardizedFileURL.path)
        let stylesheet = try XCTUnwrap(surface.schemeHandler.appResources[ServedChapter.readerStylesheetPath])
        XCTAssertTrue(String(decoding: stylesheet, as: UTF8.self).hasPrefix("@layer app-reset {"))
        let transform = try XCTUnwrap(surface.schemeHandler.transform)
        let output = String(decoding: transform(Data("<html><head></head><body></body></html>".utf8)), as: UTF8.self)
        XCTAssertTrue(output.contains(ServedChapter.readerStylesheetLink))
        XCTAssertTrue(output.contains("<style id=\"honeycrisp-user\">"))
        XCTAssertTrue(output.contains("--reader-bg: #ffffff;"))
        XCTAssertTrue(output.contains("lang=\"en\""))
    }

    func testLoadingAMissingChapterThrows() throws {
        let surface = ChapterHostSurface()
        let package = try makePackage()
        let webView = WKWebView(frame: .zero)
        XCTAssertThrowsError(try surface.load(resource: 5, in: package, into: webView))
        XCTAssertThrowsError(try surface.load(resource: -1, in: package, into: webView))
    }

    // MARK: WebKit

    /// Canary: every WebKit test below reads the page with `evaluateJavaScript` while content JavaScript
    /// is disabled. If this fails, app-evaluated scripts do not run with `allowsContentJavaScript = false`
    /// and the rest of the host design (client-world scripts, assumption A1) needs rethinking.
    func testAppEvaluatedScriptRunsWithContentJavaScriptDisabled() async throws {
        let webView = try await loadThroughSurface()
        let sum = try await webView.evaluateJavaScript("1 + 1") as? Int
        XCTAssertEqual(sum, 2)
    }

    func testSingleChapterShowsBookStylesUserFontAndRelativeImage() async throws {
        let webView = try await loadThroughSurface()
        let italic = try await string(webView, "getComputedStyle(document.getElementById('it')).fontStyle")
        let family = try await string(webView, "getComputedStyle(document.getElementById('p')).fontFamily")
        let imageWidth = try await string(webView, "document.getElementById('pic').naturalWidth")
        let language = try await string(webView, "document.documentElement.lang")
        XCTAssertEqual(italic, "italic", "class-only italic from the book stylesheet")
        XCTAssertTrue(family.contains("Georgia"), "user font family beats the book's Garamond: \(family)")
        XCTAssertEqual(imageWidth, "1", "relative image resolved in a nested directory, no URL rewriting")
        XCTAssertEqual(language, "en", "language is added when the book root has none")
    }

    func testSelfClosedAnchorDoesNotSwallowContentThroughSurface() async throws {
        let webView = try await loadThroughSurface()
        let anchorText = try await string(webView, "document.getElementById('anchor').textContent.length")
        let bodyText = try await string(webView, "document.body.textContent")
        XCTAssertEqual(anchorText, "0")
        XCTAssertTrue(bodyText.contains("after the anchor"))
    }

    func testAuthorScriptDoesNotExecuteThroughSurface() async throws {
        let surface = ChapterHostSurface()
        let package = try makePackage()
        surface.attach(package: package, cosmetics: .chapterHostFixture)

        // Positive control: the same handler and chapter with content JavaScript on runs the author script.
        let permissive = WKWebViewConfiguration()
        permissive.setURLSchemeHandler(surface.schemeHandler, forURLScheme: EPUBResourceSchemeHandler.scheme)
        let controlView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: permissive)
        try await load(package, with: surface, into: controlView)
        let controlType = try await string(controlView, "typeof window.__author")
        XCTAssertEqual(controlType, "number", "without the flag's configuration the author script is observable")

        let guarded = WKWebViewConfiguration()
        surface.install(into: guarded)
        let guardedView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: guarded)
        try await load(package, with: surface, into: guardedView)
        let guardedType = try await string(guardedView, "typeof window.__author")
        XCTAssertEqual(guardedType, "undefined", "the surface configuration must stop author scripts")
    }

    // MARK: Harness

    private func makePackage() throws -> EPUBPackage {
        let text = root.appendingPathComponent("Text", isDirectory: true)
        try Data(Self.bookCSS.utf8).write(to: root.appendingPathComponent("Styles/book.css"))
        try Data(Self.chapterXHTML.utf8).write(to: text.appendingPathComponent("Chapter 1.xhtml"))
        try Self.png.write(to: text.appendingPathComponent("Images/pic.png"))
        return EPUBPackage(
            rootFolder: root, spineURLs: [text.appendingPathComponent("Chapter 1.xhtml")],
            title: "t", author: "a", coverURL: nil, language: "en")
    }

    private func loadThroughSurface() async throws -> WKWebView {
        let surface = ChapterHostSurface()
        let package = try makePackage()
        surface.attach(package: package, cosmetics: .chapterHostFixture)
        let configuration = WKWebViewConfiguration()
        surface.install(into: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        try await load(package, with: surface, into: webView)
        return webView
    }

    private func load(_ package: EPUBPackage, with surface: ChapterHostSurface, into webView: WKWebView) async throws {
        let finished = expectation(description: "chapter loads")
        let loadDelegate = SurfaceLoadDelegate { finished.fulfill() }
        delegate = loadDelegate
        webView.navigationDelegate = loadDelegate
        try surface.load(resource: 0, in: package, into: webView)
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertNil(loadDelegate.error)
    }

    private func string(_ webView: WKWebView, _ script: String) async throws -> String {
        let value = try await webView.evaluateJavaScript(script)
        return String(describing: try XCTUnwrap(value))
    }

    // MARK: Fixture

    private static let bookCSS = """
        .i { font-style: italic; }
        p { font-family: Garamond, serif; }
        """

    private static let chapterXHTML = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title>
        <link rel="stylesheet" type="text/css" href="../Styles/book.css"/>
        <script type="text/javascript">window.__author = 1;</script></head>
        <body>
        <p id="p"><span class="i" id="it">italic</span></p>
        <p>before <a id="anchor"/>after the anchor</p>
        <img id="pic" src="Images/pic.png" alt=""/>
        </body></html>
        """

    // 1x1 RGB PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
}

private final class SurfaceLoadDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void
    private var finished = false
    private(set) var error: Error?

    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    private func finish(_ failure: Error?) {
        guard !finished else { return }
        finished = true
        error = failure
        onFinish()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { finish(error) }
}
