import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 7.2b: `qlOffsetAtCurrentColumn` is the inverse of `qlNavigateToOffset`, and the paged
/// cosmetic patch keeps the text on screen (decision B2). `PaginationEngine.currentOffset` has no test (no
/// tests exist for `PaginationEngine` beyond `RestorePosition`).
@MainActor
final class ChapterHostPagedOffsetTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// About 60 paragraphs of numbered, unique words: many columns at the harness geometry.
    private static func longChapter(_ index: Int) -> String {
        let paragraphs = (0..<60).map { n in
            "<p>Paragraph \(n) of chapter \(index). " + String(repeating: "alpha beta gamma delta epsilon ", count: 8) + "</p>"
        }.joined()
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body>\(paragraphs)</body></html>
            """
    }

    private func mount(restore: RestorePosition = .start, xhtml: ((Int) -> String)? = nil) async throws
        -> ChapterHostWindowHarness
    {
        let made = try await ChapterHostWindowHarness.makePaged(
            in: self, restore: restore, chapterXHTML: xhtml ?? Self.longChapter)
        harness = made
        for _ in 0..<100 {
            let state = try? await made.evaluate("getComputedStyle(document.documentElement).visibility")
            if state == "visible" { return made }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the paged chapter was never revealed")
        return made
    }

    private func client(_ harness: ChapterHostWindowHarness, _ body: String) async throws -> Any? {
        try await harness.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private func intValue(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? -1 }

    func testOffsetAtColumnRoundTripsThroughNavigateToOffset() async throws {
        let harness = try await mount()
        let columns = intValue(try await client(harness, "return window.qlColumnCount();"))
        XCTAssertGreaterThan(columns, 4, "the fixture chapter spans several columns")
        for target in [1, 3, columns - 1] {
            _ = try await client(harness, "window.qlScrollToColumn(\(target)); return 1;")
            let offset = intValue(try await client(harness, "return window.qlOffsetAtCurrentColumn();"))
            XCTAssertGreaterThan(offset, 0, "column \(target) starts after the beginning of the text")
            _ = try await client(harness, "window.qlScrollToColumn(0); window.qlNavigateToOffset(\(offset)); return 1;")
            let column = intValue(try await client(harness, "return window.qlCurrentColumn();"))
            XCTAssertEqual(column, target, "offset \(offset) seeks back to the column it was read from")
        }
    }

    func testOffsetAtFirstColumnIsZeroAndEmptyChapterIsZero() async throws {
        let first = try await mount()
        let firstOffset = intValue(try await client(first, "return window.qlOffsetAtCurrentColumn();"))
        XCTAssertEqual(firstOffset, 0)
        first.tearDown()
        harness = nil

        let empty = try await mount(xhtml: { _ in
            """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body><p></p></body></html>
            """
        })
        let emptyOffset = intValue(try await client(empty, "return window.qlOffsetAtCurrentColumn();"))
        XCTAssertEqual(emptyOffset, 0)
    }

    func testOffsetSurvivesFontSizeChange() async throws {
        let harness = try await mount()
        _ = try await client(harness, "window.qlScrollToColumn(4); return 1;")
        let offset = intValue(try await client(harness, "return window.qlOffsetAtCurrentColumn();"))
        XCTAssertGreaterThan(offset, 0)
        let before = intValue(try await client(harness, "return window.qlColumnCount();"))
        var bigger = ReaderCosmeticSettings.chapterHostFixture
        bigger.fontSizePercent = 150
        let patched = try await harness.surface.applyCosmetics(bigger, to: harness.webView)
        XCTAssertEqual(patched, 1)
        let after = intValue(try await client(harness, "return window.qlColumnCount();"))
        XCTAssertGreaterThan(after, before, "larger text needs more columns")
        let visible = try await isOnScreen(offset: offset, in: harness)
        XCTAssertEqual(visible, "yes", "the first text of the page before the patch is still on screen")
    }

    /// The resize and structural-reload path: reopen the chapter with `loadPaged` at the saved offset under a
    /// different geometry (decision B2). The reader's own wiring has no automated test.
    func testReloadAtOffsetUnderNewGeometryKeepsTheTextOnScreen() async throws {
        let harness = try await mount()
        _ = try await client(harness, "window.qlScrollToColumn(5); return 1;")
        let offset = intValue(try await client(harness, "return window.qlOffsetAtCurrentColumn();"))
        XCTAssertGreaterThan(offset, 0)
        _ = try await harness.evaluate("document.documentElement.setAttribute('data-old', '1'); 'ok'")
        let narrower = ChapterHostPagedGeometry(
            viewportWidth: 600, viewportHeight: 500, colsPerScreen: .one, paddingH: 24, paddingV: 24, maxWidth: 700)
        try harness.surface.loadPaged(
            resource: 2, in: harness.package, into: harness.webView, geometry: narrower,
            restore: .characterOffset(offset))
        for _ in 0..<100 {
            let state = try? await harness.evaluate(
                "document.documentElement.hasAttribute('data-old') ? 'old' : getComputedStyle(document.documentElement).visibility")
            if state == "visible" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let visible = try await isOnScreen(offset: offset, in: harness)
        XCTAssertEqual(visible, "yes", "the text read before the reload is on screen after it")
    }

    /// 'yes' when the character at `offset` (same text-node walk) has a box inside the visible page.
    private func isOnScreen(offset: Int, in harness: ChapterHostWindowHarness) async throws -> String {
        try await harness.evaluate(
            """
            (function () {
              var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), rem = \(offset), n;
              while ((n = walker.nextNode()) !== null) {
                if (rem < n.length) {
                  var r = document.createRange(); r.setStart(n, rem); r.setEnd(n, rem + 1);
                  var rects = r.getClientRects();
                  return rects.length && rects[0].left >= 0 && rects[0].left < window.innerWidth ? 'yes' : 'no';
                }
                rem -= n.length;
              }
              return 'missing';
            })()
            """)
    }
}
