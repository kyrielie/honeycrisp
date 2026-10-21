import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 6: one chapter served as a paged top-level document, columns on the root, the shared
/// `PaginationJS` running in the client world with content JavaScript off. Assumptions tested here: V2 (scripts
/// replaced per load), V4 (pager in the client world), V5 (marker span has layout), V7 (column CSS wins).
@MainActor
final class ChapterHostPagedTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func mountPaged(
        restore: RestorePosition = .start, resource: Int = 2, cosmetics: ReaderCosmeticSettings = .chapterHostFixture,
        chapterXHTML: ((Int) -> String)? = nil
    ) async throws -> ChapterHostWindowHarness {
        let made = try await ChapterHostWindowHarness.makePaged(
            in: self, resource: resource, restore: restore, cosmetics: cosmetics, chapterXHTML: chapterXHTML)
        harness = made
        try await waitUntilVisible(made)
        return made
    }

    private func waitUntilVisible(_ harness: ChapterHostWindowHarness) async throws {
        for _ in 0..<100 {
            let state = try? await harness.evaluate("getComputedStyle(document.documentElement).visibility")
            if state == "visible" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the paged chapter was never revealed")
    }

    private func client(_ harness: ChapterHostWindowHarness, _ body: String) async throws -> Any? {
        try await harness.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private func metrics(_ harness: ChapterHostWindowHarness) async throws -> (column: Int, columns: Int) {
        let json = try await client(harness, "return window.qlPaginationMetrics();") as? String
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
        return ((object["column"] as? NSNumber)?.intValue ?? -1, (object["columns"] as? NSNumber)?.intValue ?? -1)
    }

    // MARK: Pure

    func testPagedBlockAndBootstrapCarryNumbersOnly() {
        let block = ChapterHostCSS.pagedBlock(columnCSS: ChapterHostPagedGeometry.harnessFixture.columnCSS)
        XCTAssertTrue(block.contains("column-width:"))
        XCTAssertTrue(block.contains("body { padding: 0 !important; }"))
        XCTAssertTrue(block.contains("html { visibility: hidden; }"))
        let script = ChapterHostCSS.pagerBootstrap(cols: .two, restore: .characterOffset(42))
        XCTAssertTrue(script.contains("window.qlSetup(2);"))
        XCTAssertTrue(script.contains("window.qlNavigateToOffset(42);"))
        XCTAssertTrue(script.contains("document.documentElement.style.visibility = 'visible';"))
        XCTAssertTrue(script.contains("addEventListener('load', start"), "setup and restore wait for the stylesheets")
        XCTAssertTrue(script.hasSuffix("})();\n"))
        XCTAssertTrue(ChapterHostCSS.pagerBootstrap(cols: .one, restore: .fraction(7)).contains("qlScrollToFraction(1.0)"))
    }

    func testDefaultPaginationEngineStillUsesThePageWorld() {
        let webView = WKWebView()
        XCTAssertNil(PaginationEngine(webView: webView).contentWorld)
        XCTAssertEqual(PaginationEngine(webView: webView, contentWorld: .defaultClient).contentWorld, .defaultClient)
        // The merged path itself has no WebKit test (CLAUDE.md: PaginationEngine beyond RestorePosition).
    }

    // MARK: WebKit

    func testPagedBlockColumnsApplyToTheRootAndBodyWidthWins() async throws {
        let harness = try await mountPaged()
        let report = try await harness.evaluate(
            """
            (function () {
              var r = getComputedStyle(document.documentElement), b = getComputedStyle(document.body);
              return JSON.stringify({ columnWidth: parseFloat(r.columnWidth), width: parseFloat(r.width),
                maxWidth: b.maxWidth, padLeft: parseFloat(b.paddingLeft), padTop: parseFloat(b.paddingTop) });
            })()
            """)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["columnWidth"] as? Double ?? 0, 752, accuracy: 1, "800 minus two 24 px margins")
        XCTAssertEqual(decoded["width"] as? Double ?? 0, 800, accuracy: 1, "the root is the viewport wide")
        XCTAssertEqual(decoded["maxWidth"] as? String, "700px", "bodyWidthCSS beats the host stylesheet's variable")
        XCTAssertEqual(decoded["padLeft"] as? Double, 0)
        XCTAssertEqual(decoded["padTop"] as? Double, 0)
    }

    func testBookClassItalicAndCenteredVerseSurviveInPagedMode() async throws {
        let harness = try await mountPaged(chapterXHTML: { _ in
            """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title>
            <style>.it { font-style: italic; } .verse { text-align: center; }</style></head>
            <body><p class="it" id="a">italic</p><p class="verse" id="b">verse</p><p id="c">plain</p></body></html>
            """
        })
        let report = try await harness.evaluate(
            """
            JSON.stringify(['a','b','c'].map(function (id) {
              var s = getComputedStyle(document.getElementById(id)); return [s.fontStyle, s.textAlign]; }))
            """)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [[String]])
        XCTAssertEqual(rows[0][0], "italic")
        XCTAssertEqual(rows[1][1], "center")
        XCTAssertEqual(rows[2][0], "normal")
    }

    func testPagerRunsInClientWorldWithContentJavaScriptOff() async throws {
        let harness = try await mountPaged()
        let clientSetupType = try await client(harness, "return typeof window.qlSetup;") as? String
        XCTAssertEqual(clientSetupType, "function")
        let pageSetupType = try await harness.evaluate("typeof window.qlSetup")
        XCTAssertEqual(pageSetupType, "undefined", "not in the page world")
        let result = try await metrics(harness)
        XCTAssertGreaterThan(result.columns, 1, "chapter 2 is longer than one column")
    }

    func testRestoreStartEndFractionAndOffsetLandOnExpectedColumn() async throws {
        let start = try await mountPaged(restore: .start)
        let total = try await metrics(start).columns
        let startMetrics = try await metrics(start)
        XCTAssertEqual(startMetrics.column, 0)
        start.tearDown()
        harness = nil

        let end = try await mountPaged(restore: .end)
        let endMetrics = try await metrics(end)
        XCTAssertEqual(endMetrics.column, total - 1)
        end.tearDown()
        harness = nil

        let half = try await mountPaged(restore: .fraction(0.5))
        let halfMetrics = try await metrics(half)
        XCTAssertEqual(halfMetrics.column, Int((0.5 * Double(total - 1)).rounded()))
        half.tearDown()
        harness = nil

        // The fixture chapter holds about 1,000 characters of text, so a fixed offset such as 1,500 lies past the
        // end and clamps to column 0. Take three quarters of the measured text length instead.
        let probe = try await mountPaged(restore: .start)
        let textLength = try await probe.evaluate(
            """
            (function () {
              var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), total = 0, n;
              while ((n = walker.nextNode()) !== null) { total += n.length; }
              return total;
            })()
            """)
        probe.tearDown()
        harness = nil
        let offset = (Int(textLength) ?? 0) * 3 / 4
        XCTAssertGreaterThan(offset, 0, "the fixture chapter has text")
        let at = try await mountPaged(restore: .characterOffset(offset))
        let expected = try await at.evaluate(
            """
            (function () {
              var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), rem = \(offset), n;
              while ((n = walker.nextNode()) !== null) {
                if (rem < n.length) {
                  var r = document.createRange(); r.setStart(n, rem); r.setEnd(n, rem + 1);
                  var cs = getComputedStyle(document.documentElement);
                  var pitch = parseFloat(cs.columnWidth) + parseFloat(cs.columnGap);
                  return Math.floor((r.getBoundingClientRect().left + window.scrollX) / pitch);
                }
                rem -= n.length;
              }
              return -1;
            })()
            """)
        let column = try await metrics(at).column
        XCTAssertGreaterThan(column, 0, "offset \(offset) is past the first column")
        XCTAssertEqual(Double(column), Double(expected) ?? -2, accuracy: 0, "the column whose rect contains the offset (V5)")
    }

    func testPageTurnPostsPageActionAtChapterEdges() async throws {
        let last = try await mountPaged(restore: .end)
        var actions: [Bool] = []
        last.surface.onPageAction = { actions.append($0) }
        _ = try await client(last, "window.qlNextPage(); return 1;")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(actions, [true], "next at the last column posts nextSpineItem")
        last.tearDown()
        harness = nil

        let first = try await mountPaged(restore: .start)
        var back: [Bool] = []
        first.surface.onPageAction = { back.append($0) }
        _ = try await client(first, "window.qlPrevPage(); return 1;")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(back, [false], "prev at column 0 posts prevSpineItem")
    }

    func testCosmeticPatchKeepsColumnGeometryAndRecountsColumns() async throws {
        let harness = try await mountPaged()
        let before = try await metrics(harness).columns
        var bigger = ReaderCosmeticSettings.chapterHostFixture
        bigger.fontSizePercent = 150
        let patched = try await harness.surface.applyCosmetics(bigger, to: harness.webView)
        XCTAssertEqual(patched, 1)
        let after = try await metrics(harness).columns
        XCTAssertGreaterThan(after, before, "larger text needs more columns")
        let width = try await harness.evaluate("parseFloat(getComputedStyle(document.documentElement).columnWidth)")
        XCTAssertEqual(Double(width) ?? 0, 752, accuracy: 1, "the column geometry survived the patch")
        let css = try await harness.evaluate("document.getElementById('honeycrisp-user').textContent")
        XCTAssertTrue(css.contains("Honeycrisp paginated layout"), "the user block still carries the paged block")
    }

    func testPagedLoadReplacesPreviousBootstrapScript() async throws {
        let harness = try await mountPaged(restore: .start)
        let total = try await metrics(harness).columns
        let firstLoadMetrics = try await metrics(harness)
        XCTAssertEqual(firstLoadMetrics.column, 0)
        _ = try await harness.evaluate("document.documentElement.setAttribute('data-old', '1'); 'ok'")
        try harness.surface.loadPaged(
            resource: 2, in: harness.package, into: harness.webView, geometry: .harnessFixture, restore: .end)
        for _ in 0..<100 {
            let stale = try? await harness.evaluate("document.documentElement.hasAttribute('data-old') ? 'old' : 'new'")
            if stale == "new" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await waitUntilVisible(harness)
        let secondLoadMetrics = try await metrics(harness)
        XCTAssertEqual(secondLoadMetrics.column, total - 1, "the second load used its own restore, not the first")
    }
}
