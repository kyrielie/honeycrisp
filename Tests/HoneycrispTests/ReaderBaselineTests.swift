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
/// The chapter host is measured with the same generator, run count, median and footprint helpers
/// (`testHostOpen...`): `ChapterHostSurface.attach` plus `loadWindow` (the shell and three chapters as
/// iframes) until the main frame finishes, then `scrollHeight` forced on every mounted chapter document.
/// The host runs in a web view configured as `ReaderViewController.loadView` does for the flag: own
/// content controller, `ChapterHostSurface.install`.
///
/// Nothing here asserts a budget. Each test asserts only that the fixture is real (merged: chapter count
/// and non-zero layout height; host: the right three chapters mounted, sized, error free) and writes its
/// measurements to `build/diagnostics/` through `TestDiagnostics` (`baseline-<pages>-pages.txt`,
/// `host-<pages>-pages.txt`, `BASELINE` lines). Copy them into docs/ROADMAP.md M3 together with
/// `build/diagnostics/environment.txt`.
///
/// "Page" is a nominal unit of 1,800 characters of body text; the roadmap's "2,000-page book" does not
/// define it. Timings on a shared CI runner are noisy; take the numbers from a local run.
@MainActor
final class ReaderBaselineTests: XCTestCase {
    static let iterations = 3
    /// Mirrors `ReaderViewController.readerHTMLFilename` (private there).
    private static let readerFilename = "_ql_reader.html"

    var temporaryDirectory: URL!

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

    func testHostOpenOfQuarterThousandPageBook() async throws {
        try await runHostBaseline(pages: 250)
    }

    func testHostOpenOfTwoThousandPageBook() async throws {
        try await runHostBaseline(pages: 2_000)
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
        try report(pages: pages, book: book, parseMs: parseMs, samples: samples)
    }

    private func openOnce(package: EPUBPackage, parser: EPUBParser) async throws -> OpenSample {
        let footprintBefore = Self.appFootprintBytes()

        let buildStart = ContinuousClock.now
        let html = try FlowDocumentBuilder.buildDocument(package: package, cosmetics: Self.cosmetics)
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
              chapters: document.querySelectorAll('section.hc-chapter, section.ql-chapter').length
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

    // MARK: Host measurement

    private struct HostSample {
        var openMs: Double
        var frames: [HostFrame]
        var appFootprintDeltaBytes: Int64?
        var webContentFootprintBytes: UInt64?
    }

    private struct HostFrame {
        var resource: Int
        var heading: String
        var documentHeight: Int
        var paragraphs: Int
        var error: String?
    }

    private func runHostBaseline(pages: Int) async throws {
        let book = SyntheticBook(pages: pages)
        let root = temporaryDirectory.appendingPathComponent("host-book-\(pages)", isDirectory: true)
        try book.write(to: root)

        let parser = EPUBParser()
        let parseStart = ContinuousClock.now
        let package = try parser.parsePackage(at: root)
        let parseMs = Self.milliseconds(since: parseStart)
        XCTAssertEqual(package.spineURLs.count, book.chapterCount)

        // A window of three needs a chapter with a neighbour on each side.
        let center = book.chapterCount / 2
        XCTAssertGreaterThan(book.chapterCount, 2)
        var samples: [HostSample] = []
        for _ in 0..<Self.iterations {
            samples.append(try await openHostOnce(package: package, center: center))
        }
        for sample in samples {
            XCTAssertEqual(sample.frames.map(\.resource), [center - 1, center, center + 1])
            for frame in sample.frames {
                XCTAssertEqual(frame.heading, "Chapter \(frame.resource + 1)")
                XCTAssertGreaterThan(frame.documentHeight, 0, "chapter \(frame.resource) has layout")
                XCTAssertGreaterThan(frame.paragraphs, 0, "chapter \(frame.resource) has paragraphs")
                XCTAssertNil(frame.error, "chapter \(frame.resource): \(frame.error ?? "")")
            }
        }
        try reportHost(pages: pages, book: book, parseMs: parseMs, samples: samples)
    }

    private func openHostOnce(package: EPUBPackage, center: Int) async throws -> HostSample {
        let footprintBefore = Self.appFootprintBytes()

        let surface = ChapterHostSurface()
        let configuration = WKWebViewConfiguration()
        // Same order as `ReaderViewController.loadView`: own controller first, then the surface installs.
        configuration.userContentController = WKUserContentController()
        surface.install(into: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = expectation(description: "host window loads")
        let delegate = BaselineNavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate

        let openStart = ContinuousClock.now
        surface.attach(package: package, cosmetics: Self.cosmetics)
        try surface.loadWindow(around: center, in: package, into: webView)
        await fulfillment(of: [loaded], timeout: 180)
        XCTAssertNil(delegate.error)
        // Reading scrollHeight forces layout of every mounted chapter document.
        let probe = try await webView.evaluateJavaScript("""
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe.hc-frame'), function (f) {
              var d = f.contentDocument;
              var h = d ? d.querySelector('h2') : null;
              return {
                resource: Number(f.getAttribute('data-resource')),
                heading: h ? h.textContent : '',
                height: d && d.documentElement ? d.documentElement.scrollHeight : 0,
                paragraphs: d ? d.querySelectorAll('p').length : 0,
                error: f.getAttribute('data-hc-error')
              };
            }));
            """)
        let openMs = Self.milliseconds(since: openStart)
        let frames = try Self.decodeHostProbe(probe)

        let footprintAfter = Self.appFootprintBytes()
        let webContent = Self.webContentFootprintBytes(webView)
        webView.navigationDelegate = nil
        webView.stopLoading()

        var delta: Int64?
        if let footprintBefore, let footprintAfter { delta = Int64(footprintAfter) - Int64(footprintBefore) }
        return HostSample(openMs: openMs, frames: frames, appFootprintDeltaBytes: delta, webContentFootprintBytes: webContent)
    }

    private static func decodeHostProbe(_ probe: Any?) throws -> [HostFrame] {
        let json = try XCTUnwrap(probe as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return objects.map {
            HostFrame(
                resource: ($0["resource"] as? Int) ?? -1, heading: ($0["heading"] as? String) ?? "",
                documentHeight: ($0["height"] as? Int) ?? 0, paragraphs: ($0["paragraphs"] as? Int) ?? 0,
                error: $0["error"] as? String)
        }
    }

    // MARK: Reporting

    private func report(pages: Int, book: SyntheticBook, parseMs: Double, samples: [OpenSample]) throws {
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
        try TestDiagnostics.write("baseline-\(pages)-pages.txt", lines: lines)
    }

    private func reportHost(pages: Int, book: SyntheticBook, parseMs: Double, samples: [HostSample]) throws {
        var lines = [
            "BASELINE host pages=\(pages) chapters=\(book.chapterCount) window=\(samples.first?.frames.count ?? 0) iterations=\(samples.count)",
            "BASELINE host pages=\(pages) parsePackageMs=\(Self.format(parseMs)) (once)",
        ]
        for (index, sample) in samples.enumerated() {
            let heights = sample.frames.map { String($0.documentHeight) }.joined(separator: ",")
            lines.append(
                "BASELINE host pages=\(pages) run=\(index + 1) openMs=\(Self.format(sample.openMs))"
                    + " frameHeightsPx=\(heights)"
                    + " appFootprintDeltaMB=\(sample.appFootprintDeltaBytes.map { Self.megabytes($0) } ?? "unavailable")"
                    + " webContentFootprintMB=\(sample.webContentFootprintBytes.map { Self.megabytes($0) } ?? "unavailable")"
            )
        }
        let medianOpen = Self.median(samples.map(\.openMs))
        lines.append("BASELINE host pages=\(pages) medianOpenMs=\(Self.format(medianOpen))")
        lines.append("BASELINE host pages=\(pages) medianOpenPlusParseMs=\(Self.format(medianOpen + parseMs))")
        let memory = samples.compactMap(\.webContentFootprintBytes)
        if memory.isEmpty {
            lines.append("BASELINE host pages=\(pages) medianWebContentFootprintMB=unavailable")
        } else {
            let medianBytes = memory.sorted()[memory.count / 2]
            lines.append("BASELINE host pages=\(pages) medianWebContentFootprintMB=\(Self.megabytes(medianBytes))")
        }
        try TestDiagnostics.write("host-\(pages)-pages.txt", lines: lines)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }

    static func megabytes<T: BinaryInteger>(_ bytes: T) -> String {
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
    static func webContentFootprintBytes(_ webView: WKWebView) -> UInt64? {
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

    static var cosmetics: ReaderCosmeticSettings {
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

final class BaselineNavigationDelegate: NSObject, WKNavigationDelegate {
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
