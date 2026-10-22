import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 7.3: the chapter hand-off the reader performs in flag mode, replayed against the surface:
/// a page turn past an edge posts `pageAction`, `ChapterHostPaging.handoff` names the chapter and restore, and
/// `loadPaged` opens it. Decision B1: forward then back returns to the same column. The reader's own wiring
/// (`ReaderViewController.navigateSpine`, `loadHostedPagedChapter`) has no automated test.
@MainActor
final class ChapterHostPagedHandoffTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?
    private let chapterCount = 5

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func mount(resource: Int, restore: RestorePosition) async throws -> ChapterHostWindowHarness {
        let made = try await ChapterHostWindowHarness.makePaged(in: self, resource: resource, restore: restore)
        harness = made
        try await waitForChapter(resource, in: made)
        return made
    }

    /// Waits until the document is chapter `resource` and revealed.
    private func waitForChapter(_ resource: Int, in harness: ChapterHostWindowHarness) async throws {
        let name = "Chapter \(resource + 1).xhtml"
        for _ in 0..<100 {
            let state = try? await harness.evaluate(
                "decodeURIComponent(location.pathname).indexOf('\(name)') >= 0"
                + " ? getComputedStyle(document.documentElement).visibility : 'other'")
            if state == "visible" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("chapter \(resource) was never shown")
    }

    private func client(_ harness: ChapterHostWindowHarness, _ body: String) async throws -> Any? {
        try await harness.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private func metrics(_ harness: ChapterHostWindowHarness) async throws -> (column: Int, columns: Int) {
        let json = try await client(harness, "return window.qlPaginationMetrics();") as? String
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
        return ((object["column"] as? NSNumber)?.intValue ?? -1, (object["columns"] as? NSNumber)?.intValue ?? -1)
    }

    /// Turns the page in `forward` direction and, when the pager asks for a neighbour chapter, performs the
    /// reader's hand-off. Returns the chapter now showing.
    private func turn(_ harness: ChapterHostWindowHarness, from index: Int, forward: Bool) async throws -> Int {
        var requested: [Bool] = []
        harness.surface.onPageAction = { requested.append($0) }
        _ = try await client(harness, forward ? "window.qlNextPage(); return 1;" : "window.qlPrevPage(); return 1;")
        for _ in 0..<30 where requested.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(requested, [forward], "the edge posts one request")
        let target = try XCTUnwrap(ChapterHostPaging.handoff(from: index, forward: forward, count: chapterCount))
        try harness.surface.loadPaged(
            resource: target.index, in: harness.package, into: harness.webView, geometry: .harnessFixture,
            restore: target.restore)
        try await waitForChapter(target.index, in: harness)
        return target.index
    }

    func testForwardHandoffOpensTheNextChapterAtColumnZero() async throws {
        let last = try await mount(resource: 2, restore: .end)
        let shown = try await turn(last, from: 2, forward: true)
        XCTAssertEqual(shown, 3)
        let landed = try await metrics(last)
        XCTAssertEqual(landed.column, 0)
        XCTAssertGreaterThan(landed.columns, 1)
    }

    func testBackHandoffOpensThePreviousChapterAtItsLastColumn() async throws {
        let first = try await mount(resource: 3, restore: .start)
        let shown = try await turn(first, from: 3, forward: false)
        XCTAssertEqual(shown, 2)
        let landed = try await metrics(first)
        XCTAssertGreaterThan(landed.columns, 1)
        XCTAssertEqual(landed.column, landed.columns - 1)
    }

    func testForwardThenBackReturnsToTheSameColumn() async throws {
        let made = try await mount(resource: 2, restore: .end)
        let before = try await metrics(made)
        XCTAssertEqual(before.column, before.columns - 1)
        let next = try await turn(made, from: 2, forward: true)
        let back = try await turn(made, from: next, forward: false)
        XCTAssertEqual(back, 2)
        let after = try await metrics(made)
        XCTAssertEqual(after.columns, before.columns, "same geometry, same column count")
        XCTAssertEqual(after.column, before.column, "the page left is the page returned to")
    }
}
