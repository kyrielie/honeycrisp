import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Result of one paged run in `ReaderBaselineTests.testHostPagedAcrossTwentyBoundariesTwoThousandPageBook`.
struct PagedRunResult {
    var maxBytes: UInt64
    var samples: Int
    var boundaries: Int
    var openedAtColumnZero: Int
}

/// Counts `pageAction` posts from the pager (the hand-off requests a reader would act on).
private final class PageActionCounter {
    var forward = 0
}

/// The paged-memory baseline (M4 pass 7.6), kept in its own file so `ReaderBaselineTests` stays under the lint
/// length limits. It shares that class's fixtures and helpers.
extension ReaderBaselineTests {
    /// M4 pass 7.6: memory while paging through 20 consecutive chapters of the 2,000-page fixture, each reached
    /// through the real edge hand-off (`qlNextPage` at the last column posts `pageAction`,
    /// `ChapterHostPaging.handoff` names the next chapter, `loadPaged` opens it at its start). Budget: WebContent
    /// at most 30 MB (roadmap M3 budgets). Three runs, median of each run's maximum. Fails, rather than skips,
    /// when the private footprint key is unreadable (V9). Same generator, run count and footprint helper as the
    /// scroll measurement.
    func testHostPagedAcrossTwentyBoundariesTwoThousandPageBook() async throws {
        let book = SyntheticBook(pages: 2_000)
        let root = temporaryDirectory.appendingPathComponent("host-paged-book", isDirectory: true)
        try book.write(to: root)
        let package = try EPUBParser().parsePackage(at: root)
        XCTAssertGreaterThan(book.chapterCount, 30)
        var runs: [PagedRunResult] = []
        for _ in 0..<Self.iterations {
            runs.append(try await pagedRun(package: package, start: 10, boundaries: 20))
        }
        let maxima = runs.map(\.maxBytes).sorted()
        var lines = ["BASELINE host-paged pages=2000 boundaries=20 runs=\(runs.count)"]
        for (index, run) in runs.enumerated() {
            lines.append(
                "run \(index + 1): maxWebContentFootprintMB=\(Self.megabytes(run.maxBytes)) samples=\(run.samples)"
                    + " boundariesCrossed=\(run.boundaries) openedAtColumnZero=\(run.openedAtColumnZero)")
        }
        let median = maxima[maxima.count / 2]
        lines.append("BASELINE host-paged pages=2000 medianMaxWebContentFootprintMB=\(Self.megabytes(median))")
        lines.append("BASELINE host-paged pages=2000 rangeMB=\(Self.megabytes(maxima[0])) to \(Self.megabytes(maxima[maxima.count - 1]))")
        try TestDiagnostics.write("host-paged-2000-pages.txt", lines: lines)
        XCTAssertTrue(runs.allSatisfy { $0.boundaries >= 20 }, "every run crossed 20 chapter boundaries")
        XCTAssertTrue(runs.allSatisfy { $0.openedAtColumnZero == $0.boundaries }, "every hand-off opened at column 0")
        XCTAssertLessThanOrEqual(median, 30 * 1_048_576, "WebContent stays inside the M3 budget while paging")
    }

    private func pagedRun(package: EPUBPackage, start: Int, boundaries: Int) async throws -> PagedRunResult {
        let surface = ChapterHostSurface()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        surface.install(into: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        defer { webView.stopLoading() }
        let counter = PageActionCounter()
        surface.onPageAction = { forward in if forward { counter.forward += 1 } }
        surface.attach(package: package, cosmetics: Self.cosmetics)
        let geometry = ChapterHostPagedGeometry(
            viewportWidth: 800, viewportHeight: 600, colsPerScreen: .one, paddingH: 24, paddingV: 24, maxWidth: 700)
        try surface.loadPaged(resource: start, in: package, into: webView, geometry: geometry, restore: .start)
        var ready = await waitForPagedReveal(webView)
        var result = PagedRunResult(maxBytes: 0, samples: 0, boundaries: 0, openedAtColumnZero: 0)
        var current = start
        while ready, result.boundaries < boundaries {
            let before = counter.forward
            _ = try await webView.callAsyncJavaScript(
                "window.qlScrollToColumn(window.qlColumnCount() - 1); window.qlNextPage(); return 1;",
                arguments: [:], in: nil, contentWorld: .defaultClient)
            for _ in 0..<50 where counter.forward == before { try await Task.sleep(nanoseconds: 100_000_000) }
            guard counter.forward > before,
                let target = ChapterHostPaging.handoff(from: current, forward: true, count: package.spineURLs.count)
            else { XCTFail("no hand-off request at the last column of chapter \(current)"); break }
            current = target.index
            _ = try? await webView.callAsyncJavaScript(
                "document.documentElement.setAttribute('data-old', '1'); return 1;",
                arguments: [:], in: nil, contentWorld: .defaultClient)
            try surface.loadPaged(
                resource: current, in: package, into: webView, geometry: geometry, restore: target.restore)
            ready = await waitForPagedReveal(webView)
            result.boundaries += 1
            guard let bytes = Self.webContentFootprintBytes(webView) else {
                XCTFail("WebContent footprint is unreadable on this machine (V9); the memory budget cannot be checked")
                return result
            }
            result.samples += 1
            result.maxBytes = max(result.maxBytes, bytes)
            let column = try? await webView.callAsyncJavaScript(
                "return window.qlCurrentColumn();", arguments: [:], in: nil, contentWorld: .defaultClient)
            if (column as? NSNumber)?.intValue == 0 { result.openedAtColumnZero += 1 }
        }
        XCTAssertTrue(ready, "the last paged chapter was revealed")
        return result
    }

    /// True once the document that replaced the marked one has run the pager bootstrap and been revealed.
    private func waitForPagedReveal(_ webView: WKWebView) async -> Bool {
        for _ in 0..<300 {
            let state = try? await webView.callAsyncJavaScript(
                """
                if (location.protocol === 'about:' || typeof window.qlColumnCount !== 'function') { return 'wait'; }
                if (document.documentElement.hasAttribute('data-old')) { return 'wait'; }
                return getComputedStyle(document.documentElement).visibility === 'visible' ? 'ready' : 'wait';
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
            if (state as? String) == "ready" { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
