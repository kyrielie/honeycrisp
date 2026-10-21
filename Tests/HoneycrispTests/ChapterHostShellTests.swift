import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

@MainActor
final class ChapterHostShellTests: XCTestCase {
    private var root: URL!
    private var delegate: ShellLoadDelegate?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispShell-\(UUID().uuidString)", isDirectory: true)
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

    func testWindowIndicesClampAtBookEdges() {
        let window = { ChapterHostSurface.windowIndices(around: $0, count: $1) }
        XCTAssertEqual(window(0, 5), [0, 1])
        XCTAssertEqual(window(2, 5), [1, 2, 3])
        XCTAssertEqual(window(4, 5), [3, 4])
        XCTAssertEqual(window(0, 1), [0])
        XCTAssertEqual(window(0, 0), [])
        XCTAssertEqual(window(9, 5), [3, 4], "a stale index past the end is clamped first")
        XCTAssertEqual(window(-3, 5), [0, 1])
        XCTAssertEqual(ChapterHostSurface.windowIndices(around: 5, count: 11, radius: 2), [3, 4, 5, 6, 7])
    }

    func testShellHTMLOrdersFramesByResource() throws {
        let html = ChapterHostShell.html(frames: [
            .init(resource: 2, path: "/c.xhtml"), .init(resource: 0, path: "/a.xhtml"), .init(resource: 1, path: "/b.xhtml"),
        ])
        let first = try XCTUnwrap(html.range(of: "data-resource=\"0\""))
        let second = try XCTUnwrap(html.range(of: "data-resource=\"1\""))
        let third = try XCTUnwrap(html.range(of: "data-resource=\"2\""))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertLessThan(second.lowerBound, third.lowerBound)
    }

    func testShellHTMLEscapesHostileResourcePaths() {
        let html = ChapterHostShell.html(frames: [.init(resource: 0, path: "/Text/a\"><script>alert(1)</script>&'.xhtml")])
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("src=\"/Text/a&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;&amp;&apos;.xhtml\""))
    }

    func testShellHTMLIsWellFormedXMLEvenWithHostilePaths() {
        let html = ChapterHostShell.html(frames: [
            .init(resource: 0, path: "/Text/Chapter%201.xhtml"), .init(resource: 1, path: "/Text/a&b\"<c>.xhtml"),
        ])
        let parser = XMLParser(data: Data(html.utf8))
        XCTAssertTrue(parser.parse(), "the shell is served as application/xhtml+xml: \(String(describing: parser.parserError))")
    }

    func testShellHTMLContainsNoScript() {
        let html = ChapterHostShell.html(frames: [.init(resource: 0, path: "/a.xhtml")])
        XCTAssertFalse(html.lowercased().contains("<script"), "author JavaScript is off; sizing is a client-world script")
    }

    func testChapterPathKeepsPercentEncoding() {
        let path = ChapterHostSurface.chapterPath(for: root.appendingPathComponent("Text/Chapter 2.xhtml"), root: root)
        XCTAssertEqual(path, "/Text/Chapter%202.xhtml")
        XCTAssertNil(ChapterHostSurface.chapterPath(for: root.deletingLastPathComponent(), root: root))
    }

    func testClientScriptIsStaticAndRecordsErrorsInsteadOfThrowing() {
        let source = ChapterHostScript.source
        XCTAssertTrue(source.contains("data-hc-error"))
        XCTAssertTrue(source.contains("honeycrispHost"))
        XCTAssertFalse(source.contains("\\("), "no interpolated data")
    }

    // MARK: WebKit

    /// A1: with content JavaScript off, the client-world script must have run and reached into the
    /// same-scheme iframes. Zero heights mean it did not; stop and report, do not work around it.
    func testThreeChapterWindowMountsThreeSizedDocuments() async throws {
        let webView = try await loadWindow(around: 2)
        let frames = try await frameReport(webView)
        XCTAssertEqual(frames.map(\.resource), [1, 2, 3])
        for frame in frames {
            XCTAssertGreaterThan(frame.height, 0, "A1: client-world script sized frame \(frame.resource)")
            XCTAssertNil(frame.error, "frame \(frame.resource) error: \(frame.error ?? "")")
        }
        XCTAssertLessThan(frames[0].height, frames[1].height, "later fixture chapters are taller")
        XCTAssertLessThan(frames[1].height, frames[2].height)
    }

    func testWindowAtTheStartOfTheBookMountsTwoChapters() async throws {
        let webView = try await loadWindow(around: 0)
        let frames = try await frameReport(webView)
        XCTAssertEqual(frames.map(\.resource), [0, 1])
        XCTAssertTrue(frames.allSatisfy { $0.height > 0 })
    }

    func testChapterStylesDoNotLeakAcrossFrames() async throws {
        let webView = try await loadWindow(around: 2)
        let styles = try await string(
            webView,
            """
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe'), function (f) {
              var probe = f.contentDocument.getElementById('probe');
              return { resource: f.getAttribute('data-resource'), style: getComputedStyle(probe).fontStyle };
            }))
            """)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(styles.utf8)) as? [[String: String]])
        let byResource = Dictionary(uniqueKeysWithValues: decoded.map { ($0["resource"] ?? "", $0["style"] ?? "") })
        XCTAssertEqual(byResource["2"], "italic", "chapter 2's own stylesheet applies in its document")
        XCTAssertEqual(byResource["1"], "normal", "and does not reach chapter 1")
        XCTAssertEqual(byResource["3"], "normal", "or chapter 3")
        let shellProbe = try await string(webView, "document.getElementById('probe') === null")
        XCTAssertEqual(shellProbe, "1", "duplicate ids live in separate documents, not in the shell")
    }

    func testRelativeImagesResolveInNestedLayoutInEveryFrame() async throws {
        let webView = try await loadWindow(around: 2)
        let widths = try await string(
            webView,
            """
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe'), function (f) {
              return f.contentDocument.getElementById('pic').naturalWidth;
            }))
            """)
        XCTAssertEqual(widths, "[1,1,1]")
    }

    // MARK: Harness

    private struct FrameReport {
        let resource: Int
        let height: Double
        let error: String?
    }

    private func frameReport(_ webView: WKWebView) async throws -> [FrameReport] {
        let json = try await string(
            webView,
            """
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe.hc-frame'), function (f) {
              return { resource: Number(f.getAttribute('data-resource')), height: f.getBoundingClientRect().height,
                       error: f.getAttribute('data-hc-error') };
            }))
            """)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        return decoded.map {
            FrameReport(
                resource: ($0["resource"] as? Int) ?? -1, height: ($0["height"] as? Double) ?? 0,
                error: $0["error"] as? String)
        }
    }

    private func loadWindow(around index: Int) async throws -> WKWebView {
        let package = try makePackage(chapters: 5)
        let surface = ChapterHostSurface()
        surface.attach(package: package, cosmetics: .chapterHostFixture)
        let configuration = WKWebViewConfiguration()
        // Same order as `ReaderViewController.loadView`: own controller first, then the surface installs.
        configuration.userContentController = WKUserContentController()
        surface.install(into: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let finished = expectation(description: "shell and chapters load")
        let loadDelegate = ShellLoadDelegate { finished.fulfill() }
        delegate = loadDelegate
        webView.navigationDelegate = loadDelegate
        try surface.loadWindow(around: index, in: package, into: webView)
        await fulfillment(of: [finished], timeout: 20)
        XCTAssertNil(loadDelegate.error)
        retainedSurface = surface
        return webView
    }

    private var retainedSurface: ChapterHostSurface?

    private func string(_ webView: WKWebView, _ script: String) async throws -> String {
        let value = try await webView.evaluateJavaScript(script)
        return String(describing: try XCTUnwrap(value))
    }

    // MARK: Fixture

    /// Chapter i has i * 15 + 5 paragraphs, so heights grow with the index. Every chapter links its own
    /// stylesheet; only chapter 2's makes `.x` italic. Every chapter has a `#probe` and a relative image.
    private func makePackage(chapters: Int) throws -> EPUBPackage {
        let text = root.appendingPathComponent("Text", isDirectory: true)
        try Self.png.write(to: text.appendingPathComponent("Images/pic.png"))
        var urls: [URL] = []
        for index in 0..<chapters {
            let css = index == 2 ? ".x { font-style: italic; }" : "/* chapter \(index) */"
            try Data(css.utf8).write(to: root.appendingPathComponent("Styles/book\(index).css"))
            let paragraphs = (0..<(index * 15 + 5)).map { "<p>Paragraph \($0) of chapter \(index).</p>" }.joined(separator: "\n")
            let xhtml = """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c\(index)</title>
                <link rel="stylesheet" type="text/css" href="../Styles/book\(index).css"/></head>
                <body><p class="x" id="probe">probe</p>
                <img id="pic" src="Images/pic.png" alt=""/>
                \(paragraphs)
                </body></html>
                """
            let url = text.appendingPathComponent("Chapter \(index + 1).xhtml")
            try Data(xhtml.utf8).write(to: url)
            urls.append(url)
        }
        return EPUBPackage(
            rootFolder: root, spineURLs: urls, title: "t", author: "a", coverURL: nil, language: "en")
    }

    // 1x1 RGB PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
}

private final class ShellLoadDelegate: NSObject, WKNavigationDelegate {
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
