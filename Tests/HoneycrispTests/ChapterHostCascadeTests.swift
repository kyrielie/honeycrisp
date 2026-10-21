import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M3 / contract C4, proven in WebKit: a chapter served through `EPUBResourceSchemeHandler` with
/// the book's own stylesheet plus `ChapterHostCSS`. The web view is a plain one with JavaScript on; the
/// cascade does not depend on JavaScript and these tests must not depend on assumption A1 (client-world
/// scripts with content JS off), which pass 6 covers.
@MainActor
final class ChapterHostCascadeTests: XCTestCase {
    private var root: URL!
    private var handler: EPUBResourceSchemeHandler!
    private var delegate: CascadeLoadDelegate?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispCascade-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        for directory in ["Text/Images", "Styles"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
        try Data(Self.bookCSS.utf8).write(to: root.appendingPathComponent("Styles/book.css"))
        try Data(Self.chapterXHTML.utf8).write(to: root.appendingPathComponent("Text/ch1.xhtml"))
        try Self.png.write(to: root.appendingPathComponent("Text/Images/pic.png"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: Tests

    func testCascadeLayersAreSupported() async throws {
        let webView = try await loadChapter()
        let type = try await evaluate(webView, "typeof CSSLayerBlockRule")
        XCTAssertEqual(type, "function", "the reset layer would be silently ignored without @layer support")
    }

    func testClassOnlyItalicSurvivesUserLayer() async throws {
        let webView = try await loadChapter()
        let style = try await computed(webView, "it", "font-style")
        XCTAssertEqual(style, "italic")
    }

    func testCenteredVerseSurvivesJustifiedUserAlignment() async throws {
        var cosmetics = ReaderCosmeticSettings.chapterHostFixture
        cosmetics.textAlignment = .justify
        let webView = try await loadChapter(cosmetics: cosmetics)
        let verse = try await computed(webView, "verse", "text-align")
        let plain = try await computed(webView, "plain", "text-align")
        XCTAssertEqual(verse, "center", "a book class beats the user's optional alignment")
        XCTAssertEqual(plain, "justify", "the book's plain `p { text-align: left }` loses on source order")
    }

    func testBookAlignmentAndIndentAreKeptWhenSettingsAreBookDefault() async throws {
        let webView = try await loadChapter()
        let align = try await computed(webView, "plain", "text-align")
        let indent = try await computed(webView, "plain", "text-indent")
        XCTAssertEqual(align, "left")
        XCTAssertEqual(indent, "20px")
    }

    func testParagraphIndentAppliesOnlyWhenSet() async throws {
        var cosmetics = ReaderCosmeticSettings.chapterHostFixture
        cosmetics.paragraphIndent = 2
        let webView = try await loadChapter(cosmetics: cosmetics)
        let indent = try await computed(webView, "plain", "text-indent")
        // 2em of the 17.6px body text (1.1rem of 16px).
        XCTAssertEqual(try XCTUnwrap(Self.pixels(indent)), 35.2, accuracy: 0.1)
    }

    func testUserFontFamilyColorSizeAndLineHeightBeatBookRules() async throws {
        let webView = try await loadChapter()
        let family = try await computed(webView, "plain", "font-family")
        let color = try await computed(webView, "plain", "color")
        let bodySize = try await computed(webView, "body", "font-size")
        let lineHeight = try await computed(webView, "plain", "line-height")
        XCTAssertTrue(family.contains("Georgia"), family)
        XCTAssertEqual(color, "rgb(0, 0, 0)")
        XCTAssertEqual(try XCTUnwrap(Self.pixels(bodySize)), 17.6, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(Self.pixels(lineHeight)), 1.6 * 17.6, accuracy: 0.1)
    }

    func testUserBackgroundAppliesToDocument() async throws {
        let webView = try await loadChapter()
        let html = try await evaluate(webView, "getComputedStyle(document.documentElement).backgroundColor")
        let body = try await computed(webView, "body", "background-color")
        XCTAssertEqual(html, "rgb(255, 255, 255)")
        XCTAssertEqual(body, "rgba(0, 0, 0, 0)", "the book's #eeeeee body background is dropped")
    }

    func testLinkColorIsTheUserLinkColor() async throws {
        let webView = try await loadChapter()
        let color = try await computed(webView, "link", "color")
        XCTAssertEqual(color, "rgb(0, 104, 218)", "the book's red link color must lose to the user's")
    }

    func testBodyWidthAndPaddingComeFromUserSettings() async throws {
        let webView = try await loadChapter()
        let maxWidth = try await computed(webView, "body", "max-width")
        let padding = try await computed(webView, "body", "padding-left")
        XCTAssertEqual(maxWidth, "700px")
        XCTAssertEqual(padding, "24px")
    }

    func testBookBoldSmallCapsAndUnderlineAreNotOverridden() async throws {
        var cosmetics = ReaderCosmeticSettings.chapterHostFixture
        cosmetics.boldWeight = .normal
        let webView = try await loadChapter(cosmetics: cosmetics)
        let smallCaps = try await computed(webView, "sc", "font-variant-caps")
        let underline = try await computed(webView, "ul", "text-decoration-line")
        let boldClass = try await computed(webView, "boldclass", "font-weight")
        let boldElement = try await computed(webView, "b", "font-weight")
        XCTAssertEqual(smallCaps, "small-caps")
        XCTAssertEqual(underline, "underline")
        XCTAssertEqual(boldClass, "700", "a class-only bold is the book's meaning, not the user's weight")
        XCTAssertEqual(boldElement, "400", "the user's weight applies to <b> and <strong> only")
    }

    func testOversizedImageIsContainedToContentWidth() async throws {
        let webView = try await loadChapter()
        let width = try await evaluate(webView, "document.getElementById('wide').getBoundingClientRect().width")
        // 700 px body, 24 px padding on each side.
        XCTAssertLessThanOrEqual(try XCTUnwrap(Double(width)), 652.5)
    }

    func testResetLayerAppliesButLosesToABookRule() async throws {
        let webView = try await loadChapter()
        let control = try await computed(webView, "control", "box-sizing")
        let boxed = try await computed(webView, "boxed", "box-sizing")
        XCTAssertEqual(control, "border-box", "the reset layer applies where the book is silent")
        XCTAssertEqual(boxed, "content-box", "an unlayered book rule beats the reset layer")
    }

    // MARK: Harness

    private func loadChapter(
        cosmetics: ReaderCosmeticSettings = .chapterHostFixture
    ) async throws -> WKWebView {
        handler = EPUBResourceSchemeHandler(rootFolder: root)
        handler.appResources[ServedChapter.readerStylesheetPath] = Data(ChapterHostCSS.stylesheet.utf8)
        let userCSS = ChapterHostCSS.userBlock(cosmetics)
        handler.transform = { ServedChapter.prepare($0, language: "en", userCSS: userCSS) }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: EPUBResourceSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let finished = expectation(description: "chapter loads")
        let loadDelegate = CascadeLoadDelegate { finished.fulfill() }
        delegate = loadDelegate
        webView.navigationDelegate = loadDelegate
        webView.load(URLRequest(url: URL(string: "honeycrisp-epub://book/Text/ch1.xhtml")!))
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertNil(loadDelegate.error)
        return webView
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async throws -> String {
        let value = try await webView.evaluateJavaScript(script)
        return String(describing: try XCTUnwrap(value))
    }

    private func computed(_ webView: WKWebView, _ id: String, _ property: String) async throws -> String {
        let element = id == "body" ? "document.body" : "document.getElementById('\(id)')"
        return try await evaluate(webView, "getComputedStyle(\(element)).getPropertyValue('\(property)')")
    }

    private static func pixels(_ value: String) -> Double? {
        value.hasSuffix("px") ? Double(value.dropLast(2)) : nil
    }

    // MARK: Fixture

    private static let bookCSS = """
        .boxed { box-sizing: content-box; }
        body { font-size: 12px; margin: 40px; background: #eeeeee; color: #222222; }
        p { font-family: Garamond, serif; color: #336699; line-height: 1; margin: 0; text-indent: 20px; text-align: left; }
        .verse { text-align: center; }
        .i { font-style: italic; }
        .sc { font-variant: small-caps; }
        .ul { text-decoration: underline; }
        .bold { font-weight: 700; }
        a { color: #ff0000; }
        img.wide { width: 5000px; }
        """

    private static let chapterXHTML = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title>
        <link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
        <body>
        <p id="plain">Plain paragraph</p>
        <p class="verse" id="verse">Verse line</p>
        <p><span class="i" id="it">italic</span> <span class="sc" id="sc">small</span> <span class="ul" id="ul">under</span></p>
        <p><b id="b">bold</b> <span class="bold" id="boldclass">bold class</span></p>
        <p><a id="link" href="#x">link</a></p>
        <div id="boxed" class="boxed">book content-box</div><div id="control">no book rule</div>
        <img id="wide" class="wide" src="Images/pic.png" alt=""/>
        </body></html>
        """

    // 1x1 RGB PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
}

private final class CascadeLoadDelegate: NSObject, WKNavigationDelegate {
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
