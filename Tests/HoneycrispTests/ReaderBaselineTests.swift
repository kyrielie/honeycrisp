import AppKit
import Darwin
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// BASELINE (roadmap M3 exit criteria): measures how the current merged-document reader opens a large
/// synthetic book, so the M3 time and memory budgets can be set from numbers instead of guesses.
///
/// Path measured, same calls as `ReaderViewController.renderScrollContent`: `parsePackage`,
/// `buildScrollHTML` (every chapter merged into one document), write `_ql_reader.html`, then
/// `WKWebView.loadFileURL`. The web view here is a plain default one: the production view also has
/// script message handlers and user scripts, so absolute times are a floor, not the app's real number.
///
/// Nothing here asserts a budget. Each test asserts only that the fixture is real (chapter count,
/// non-zero layout height) and records its measurements as kept attachments and as `BASELINE` lines on
/// stdout. Copy them into docs/ROADMAP.md M3 together with the macOS and Xcode versions.
///
/// "Page" is a nominal unit of 1,800 characters of body text; the roadmap's "2,000-page book" does not
/// define it. Timings on a shared CI runner are noisy; take the numbers from a local run.
@MainActor
final class ReaderBaselineTests: XCTestCase {
    private static let iterations = 3
    /// Mirrors `ReaderViewController.readerHTMLFilename` (private there).
    private static let readerFilename = "_ql_reader.html"

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispBaseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try super.tearDownWithError()
    }

    func testBaselineOpenOfQuarterThousandPageBook() async throws {
        try await runBaseline(pages: 250)
    }

    func testBaselineOpenOfTwoThousandPageBook() async throws {
        try await runBaseline(pages: 2_000)
    }

    // MARK: Measurement

    private struct OpenSample {
        var buildMs: Double
        var writeMs: Double
        var loadAndLayoutMs: Double
        var htmlBytes: Int
        var scrollHeight: Int
        var chapterElements: Int
        var appFootprintDeltaBytes: Int64?
        var webContentFootprintBytes: UInt64?
    }

    private func runBaseline(pages: Int) async throws {
        let book = SyntheticBook(pages: pages)
        let root = temporaryDirectory.appendingPathComponent("book-\(pages)", isDirectory: true)
        try book.write(to: root)

        let parser = EPUBParser()
        let parseStart = ContinuousClock.now
        let package = try parser.parsePackage(at: root)
        let parseMs = Self.milliseconds(since: parseStart)
        XCTAssertEqual(package.spineURLs.count, book.chapterCount)

        var samples: [OpenSample] = []
        for _ in 0..<Self.iterations {
            samples.append(try await openOnce(package: package, parser: parser))
        }
        for sample in samples {
            XCTAssertEqual(sample.chapterElements, book.chapterCount)
            XCTAssertGreaterThan(sample.scrollHeight, 0)
        }
        report(pages: pages, book: book, parseMs: parseMs, samples: samples)
    }

    private func openOnce(package: EPUBPackage, parser: EPUBParser) async throws -> OpenSample {
        let footprintBefore = Self.appFootprintBytes()

        let buildStart = ContinuousClock.now
        let html = try parser.buildScrollHTML(from: package, cosmetics: Self.cosmetics)
        let buildMs = Self.milliseconds(since: buildStart)

        let writeStart = ContinuousClock.now
        let indexURL = package.rootFolder.appendingPathComponent(Self.readerFilename)
        try html.write(to: indexURL, atomically: true, encoding: .utf8)
        let writeMs = Self.milliseconds(since: writeStart)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loaded = expectation(description: "baseline book loads")
        let delegate = BaselineNavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        let loadStart = ContinuousClock.now
        webView.loadFileURL(indexURL, allowingReadAccessTo: package.rootFolder)
        await fulfillment(of: [loaded], timeout: 180)
        XCTAssertNil(delegate.error)
        // Reading scrollHeight forces layout, so this interval is load plus first full layout.
        let probe = try await webView.evaluateJavaScript("""
            JSON.stringify({
              height: document.documentElement.scrollHeight,
              chapters: document.querySelectorAll('section.ql-chapter').length
            });
            """)
        let loadAndLayoutMs = Self.milliseconds(since: loadStart)
        let values = try Self.decodeProbe(probe)

        let footprintAfter = Self.appFootprintBytes()
        let webContent = Self.webContentFootprintBytes(webView)
        webView.navigationDelegate = nil
        webView.stopLoading()
        try? FileManager.default.removeItem(at: indexURL)

        var delta: Int64?
        if let footprintBefore, let footprintAfter { delta = Int64(footprintAfter) - Int64(footprintBefore) }
        return OpenSample(
            buildMs: buildMs, writeMs: writeMs, loadAndLayoutMs: loadAndLayoutMs,
            htmlBytes: html.utf8.count, scrollHeight: values.height, chapterElements: values.chapters,
            appFootprintDeltaBytes: delta, webContentFootprintBytes: webContent
        )
    }

    private static func decodeProbe(_ probe: Any?) throws -> (height: Int, chapters: Int) {
        let json = try XCTUnwrap(probe as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        return (try XCTUnwrap(object["height"]), try XCTUnwrap(object["chapters"]))
    }

    // MARK: Reporting

    private func report(pages: Int, book: SyntheticBook, parseMs: Double, samples: [OpenSample]) {
        var lines = [
            "BASELINE pages=\(pages) chapters=\(book.chapterCount) iterations=\(samples.count)",
            "BASELINE pages=\(pages) parsePackageMs=\(Self.format(parseMs)) (once)",
        ]
        for (index, sample) in samples.enumerated() {
            lines.append(
                "BASELINE pages=\(pages) run=\(index + 1) buildScrollHTMLMs=\(Self.format(sample.buildMs))"
                    + " writeMs=\(Self.format(sample.writeMs)) loadAndLayoutMs=\(Self.format(sample.loadAndLayoutMs))"
                    + " htmlMB=\(Self.megabytes(UInt64(sample.htmlBytes))) scrollHeightPx=\(sample.scrollHeight)"
                    + " appFootprintDeltaMB=\(sample.appFootprintDeltaBytes.map { Self.megabytes($0) } ?? "unavailable")"
                    + " webContentFootprintMB=\(sample.webContentFootprintBytes.map { Self.megabytes($0) } ?? "unavailable")"
            )
        }
        let medianLoad = Self.median(samples.map(\.loadAndLayoutMs))
        lines.append("BASELINE pages=\(pages) medianLoadAndLayoutMs=\(Self.format(medianLoad))")
        for line in lines { print(line) }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "baseline-\(pages)-pages"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func megabytes<T: BinaryInteger>(_ bytes: T) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    // MARK: Memory (best effort, never fails a test)

    /// Physical footprint of this process (the app host), in bytes. Does not include the WebContent process.
    private static func appFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Physical footprint of the web view's WebContent process. Reads a private WebKit key
    /// (`_webProcessIdentifier`) and `proc_pid_rusage`, so it is guarded and returns nil when either is
    /// unavailable (for example under the App Sandbox). Test-only; never move this into `Sources/`.
    private static func webContentFootprintBytes(_ webView: WKWebView) -> UInt64? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
            let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        var usage = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    // MARK: Fixture

    private static var cosmetics: ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: 100,
            fontFamily: "Georgia, serif",
            backgroundCSS: "#ffffff",
            textCSS: "#000000",
            linkCSS: "#0068da",
            hitBackground: "#ffee58",
            hitText: "#000000",
            hitActiveBackground: "#ffa000",
            hitActiveText: "#000000",
            lineHeight: 1.6,
            maxWidth: 700,
            paddingH: 24,
            allowLinkClicks: true
        )
    }
}

/// Generates a deterministic EPUB folder (EPUB 3 package, nested `Text/` and `Styles/`, one relative
/// image per chapter, a book stylesheet with class-only italics) of a requested nominal page count.
private struct SyntheticBook {
    static let charactersPerPage = 1_800
    static let pagesPerChapter = 20
    static let paragraphCharacters = 300
    static let imageVariants = 8

    // 1x1 RGB PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    private static let words = [
        "the", "lantern", "burned", "low", "while", "she", "counted", "every", "step", "back", "toward", "home",
        "and", "nobody", "answered", "when", "he", "asked", "about", "the", "river", "&amp;", "its", "long", "memory",
    ]

    let pages: Int

    var chapterCount: Int { (pages + Self.pagesPerChapter - 1) / Self.pagesPerChapter }

    func write(to root: URL) throws {
        let fileManager = FileManager.default
        let oebps = root.appendingPathComponent("OEBPS", isDirectory: true)
        let text = oebps.appendingPathComponent("Text", isDirectory: true)
        let images = text.appendingPathComponent("Images", isDirectory: true)
        let styles = oebps.appendingPathComponent("Styles", isDirectory: true)
        let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
        for directory in [images, styles, metaInf] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(
            """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8
        ).write(to: metaInf.appendingPathComponent("container.xml"))
        try Data(".i { font-style: italic; } .fig { text-align: center; } .verse { text-align: center; }".utf8)
            .write(to: styles.appendingPathComponent("book.css"))
        for variant in 0..<Self.imageVariants {
            try Self.png.write(to: images.appendingPathComponent("fig\(variant).png"))
        }
        for chapter in 0..<chapterCount {
            try Data(chapterXHTML(index: chapter).utf8).write(to: text.appendingPathComponent("chapter\(chapter).xhtml"))
        }
        try Data(packageOPF().utf8).write(to: oebps.appendingPathComponent("package.opf"))
    }

    private func packageOPF() -> String {
        let chapters = (0..<chapterCount)
            .map { "<item id=\"c\($0)\" href=\"Text/chapter\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }
            .joined(separator: "\n    ")
        let spine = (0..<chapterCount).map { "<itemref idref=\"c\($0)\"/>" }.joined(separator: "\n    ")
        return """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Synthetic \(pages) pages</dc:title><dc:creator>Baseline</dc:creator><dc:language>en</dc:language>
              </metadata>
              <manifest>
                \(chapters)
                <item id="css" href="Styles/book.css" media-type="text/css"/>
              </manifest>
              <spine>
                \(spine)
              </spine>
            </package>
            """
    }

    private func chapterXHTML(index: Int) -> String {
        let pagesHere = min(Self.pagesPerChapter, pages - index * Self.pagesPerChapter)
        let paragraphCount = max(1, pagesHere * Self.charactersPerPage / Self.paragraphCharacters)
        let body = (0..<paragraphCount).map { paragraph(chapter: index, number: $0) }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Chapter \(index)</title>
            <link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
            <body><h2>Chapter \(index + 1)</h2>
            <p class="fig"><img src="Images/fig\(index % Self.imageVariants).png" alt=""/></p>
            \(body)
            </body></html>
            """
    }

    private func paragraph(chapter: Int, number: Int) -> String {
        var text = ""
        var cursor = chapter * 7 + number * 13
        while text.count < Self.paragraphCharacters {
            text += (text.isEmpty ? "" : " ") + Self.words[cursor % Self.words.count]
            cursor += 1
        }
        if number % 5 == 0 { return "<p><span class=\"i\">\(text)</span></p>" }
        if number % 11 == 0 { return "<p class=\"verse\">\(text)</p>" }
        return "<p>\(text)</p>"
    }
}

private final class BaselineNavigationDelegate: NSObject, WKNavigationDelegate {
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
