import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Result of one scroll run in `ReaderBaselineTests.testHostScrollAcrossTwentyBoundariesTwoThousandPageBook`.
struct ScrollRunResult {
    var maxBytes: UInt64
    var samples: Int
    var mountedAtMax: Int
    var boundaries: Int
}

/// The scroll-memory baseline (M4 pass 5), kept in its own file so `ReaderBaselineTests` stays under the lint
/// length limits. It shares that class's fixtures and helpers.
extension ReaderBaselineTests {
    /// M4 pass 5: memory while scrolling through the real client script across 20 chapter boundaries of the
    /// 2,000-page fixture (budget: WebContent at most 30 MB, roadmap M3 budgets). Three runs, median of each
    /// run's maximum. Fails, rather than skips, when the private footprint key is unreadable (V9).
    func testHostScrollAcrossTwentyBoundariesTwoThousandPageBook() async throws {
        let book = SyntheticBook(pages: 2_000)
        let root = temporaryDirectory.appendingPathComponent("host-scroll-book", isDirectory: true)
        try book.write(to: root)
        let package = try EPUBParser().parsePackage(at: root)
        XCTAssertGreaterThan(book.chapterCount, 30)
        var runs: [ScrollRunResult] = []
        for _ in 0..<Self.iterations {
            runs.append(try await scrollRun(package: package, start: 10, boundaries: 20))
        }
        let maxima = runs.map(\.maxBytes).sorted()
        var lines = ["BASELINE host-scroll pages=2000 boundaries=20 runs=\(runs.count)"]
        for (index, run) in runs.enumerated() {
            lines.append(
                "run \(index + 1): maxWebContentFootprintMB=\(Self.megabytes(run.maxBytes)) samples=\(run.samples)"
                    + " mountedAtMax=\(run.mountedAtMax) boundariesCrossed=\(run.boundaries)")
        }
        let median = maxima[maxima.count / 2]
        lines.append("BASELINE host-scroll pages=2000 medianMaxWebContentFootprintMB=\(Self.megabytes(median))")
        lines.append("BASELINE host-scroll pages=2000 rangeMB=\(Self.megabytes(maxima[0])) to \(Self.megabytes(maxima[maxima.count - 1]))")
        try TestDiagnostics.write("host-scroll-2000-pages.txt", lines: lines)
        XCTAssertTrue(runs.allSatisfy { $0.boundaries >= 20 }, "every run crossed 20 chapter boundaries")
        XCTAssertLessThanOrEqual(median, 30 * 1_048_576, "WebContent stays inside the M3 budget while scrolling")
    }

    private func scrollRun(
        package: EPUBPackage, start: Int, boundaries: Int
    ) async throws -> ScrollRunResult {
        let surface = ChapterHostSurface()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        surface.install(into: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = expectation(description: "host window loads")
        let delegate = BaselineNavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        surface.attach(package: package, cosmetics: Self.cosmetics)
        try surface.loadWindow(around: start, in: package, into: webView, restoring: .start)
        await fulfillment(of: [loaded], timeout: 180)
        XCTAssertNil(delegate.error)
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        var maxBytes: UInt64 = 0, mountedAtMax = 0, samples = 0, crossed = 0
        var lastResource: Int?
        var steps = 0
        while crossed < boundaries, steps < 4_000 {
            steps += 1
            let report = try await webView.callAsyncJavaScript(
                """
                window.scrollBy(0, Math.round(window.innerHeight * 0.8));
                var mounted = window.honeycrispHost.reconcile();
                var pos = window.honeycrispHost.offsetOfFirstVisibleText();
                return JSON.stringify({ mounted: mounted, resource: pos ? pos.resource : -1 });
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
            try await Task.sleep(nanoseconds: 20_000_000)
            guard let json = report as? String,
                let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int],
                let resource = object["resource"], resource >= 0
            else { continue }
            guard let previous = lastResource else { lastResource = resource; continue }
            guard resource != previous else { continue }
            lastResource = resource
            crossed += 1
            guard let bytes = Self.webContentFootprintBytes(webView) else {
                XCTFail("WebContent footprint is unreadable on this machine (V9); the memory budget cannot be checked")
                return ScrollRunResult(maxBytes: 0, samples: samples, mountedAtMax: mountedAtMax, boundaries: crossed)
            }
            samples += 1
            if bytes > maxBytes {
                maxBytes = bytes
                mountedAtMax = object["mounted"] ?? 0
            }
        }
        return ScrollRunResult(maxBytes: maxBytes, samples: samples, mountedAtMax: mountedAtMax, boundaries: crossed)
    }
}
