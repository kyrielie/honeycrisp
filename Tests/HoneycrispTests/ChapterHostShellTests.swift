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

    /// Resources of the mounted frames whose last paragraph lies below the frame's bottom edge.
    private func clippedFrames(_ webView: WKWebView) async throws -> [Int] {
        let json = try await string(
            webView,
            """
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe.hc-frame'), function (f) {
              var ps = f.contentDocument.getElementsByTagName('p'), last = ps[ps.length - 1];
              return { resource: Number(f.getAttribute('data-resource')), frame: f.clientHeight,
                       lastBottom: Math.round(last.getBoundingClientRect().bottom + f.contentWindow.scrollY) };
            }))
            """)
        let frames = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(frames.count, 3)
        return frames.compactMap { frame in
            let height = (frame["frame"] as? Double) ?? 0
            let bottom = (frame["lastBottom"] as? Double) ?? .infinity
            return bottom > height + 1 ? (frame["resource"] as? Int) ?? -1 : nil
        }
    }

    /// Regression: the first measurement of the second and third frame was about 500 px short and was never
    /// corrected, so their last paragraphs lay below the frame and `scrollTo` landed in the next chapter.
    func testNoMountedChapterIsClippedByItsFrameOnceTheWindowHasLoaded() async throws {
        let webView = try await loadWindow(around: 2)
        let clipped = try await clippedFrames(webView)
        XCTAssertEqual(clipped, [], "frames that clip their last paragraph")
    }

    /// The resize path (`resize` event, then `fitAll` after 50 ms) re-fits in both directions: a narrow window
    /// rewraps the text so every frame grows and none clips; widening again restores the original heights.
    func testFramesRefitWhenTheWindowIsResizedNarrowerAndWiderAgain() async throws {
        let webView = try await loadWindow(around: 2)
        let original = try await frameReport(webView).map(\.height)
        XCTAssertTrue(original.allSatisfy { $0 > 0 })

        webView.setFrameSize(NSSize(width: 160, height: 600))
        var narrow = original
        for _ in 0..<60 where zip(original, narrow).contains(where: { $0.1 <= $0.0 }) {
            try await Task.sleep(nanoseconds: 50_000_000)
            narrow = try await frameReport(webView).map(\.height)
        }
        for (old, new) in zip(original, narrow) { XCTAssertGreaterThan(new, old, "narrower text wraps, so the frame grows") }
        let clippedNarrow = try await clippedFrames(webView)
        XCTAssertEqual(clippedNarrow, [], "no frame clips its content after narrowing")

        webView.setFrameSize(NSSize(width: 800, height: 600))
        var wide = narrow
        for _ in 0..<60 where zip(original, wide).contains(where: { abs($0.1 - $0.0) > 2 }) {
            try await Task.sleep(nanoseconds: 50_000_000)
            wide = try await frameReport(webView).map(\.height)
        }
        for (old, new) in zip(original, wide) { XCTAssertEqual(new, old, accuracy: 2, "widening shrinks the frame again") }
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
