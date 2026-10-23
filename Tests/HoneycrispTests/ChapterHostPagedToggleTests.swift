import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 7.5, contract C2 (U2): the scroll window and the pager count offsets the same way, so a
/// position read in one reopens on the same text in the other. The reader's own wiring
/// (`ReaderViewController.toggleHostedReadingMode`) has no automated test.
@MainActor
final class ChapterHostPagedToggleTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// Long, numbered paragraphs: many columns paged, several screens scrolled.
    private static func longChapter(_ index: Int) -> String {
        let paragraphs = (0..<60).map { paragraphIndex in
            "<p>Paragraph \(paragraphIndex) of chapter \(index). " + String(repeating: "alpha beta gamma delta epsilon ", count: 8) + "</p>"
        }.joined()
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body>\(paragraphs)</body></html>
            """
    }

    private func client(_ harness: ChapterHostWindowHarness, _ body: String) async throws -> Any? {
        try await harness.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    /// 20 characters of body text from `offset` (same text-node walk), read in the paged document.
    private func pagedSnippet(_ offset: Int, in harness: ChapterHostWindowHarness) async throws -> String {
        try await harness.evaluate(
            """
            (function () {
              var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), all = '', n;
              while ((n = walker.nextNode()) !== null) { all += n.data; }
              return all.substr(\(offset), 20);
            })()
            """)
    }

    /// 'yes' when the character at `offset` has a box inside the visible page of the paged document.
    private func pagedOnScreen(_ offset: Int, in harness: ChapterHostWindowHarness) async throws -> String {
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

    /// 20 characters from `offset` in the scroll window's frame for `resource`, and whether that character is
    /// inside the window's visible height ('yes' or 'no'), as `snippet|visible`.
    private func shellState(_ offset: Int, resource: Int, in harness: ChapterHostWindowHarness) async throws -> String {
        try await harness.evaluate(
            """
            (function () {
              var f = document.querySelector('iframe.hc-frame[data-resource="\(resource)"]');
              if (!f || !f.contentDocument || !f.contentDocument.body) { return 'noframe'; }
              var d = f.contentDocument;
              var walker = d.createTreeWalker(d.body, NodeFilter.SHOW_TEXT, null), all = '', rem = \(offset), found = null, local = 0, n;
              while ((n = walker.nextNode()) !== null) {
                if (found === null && rem < n.length) { found = n; local = rem; }
                rem -= n.length;
                all += n.data;
              }
              if (!found) { return 'missing'; }
              var r = d.createRange(); r.setStart(found, local); r.setEnd(found, local + 1);
              var rects = r.getClientRects();
              var top = rects.length ? f.getBoundingClientRect().top + rects[0].top : -1;
              return all.substr(\(offset), 20) + '|' + (top >= 0 && top < window.innerHeight ? 'yes' : 'no');
            })()
            """)
    }

    func testOffsetFromShellOpensPagedOnTheSameText() async throws {
        let made = try await ChapterHostWindowHarness.make(in: self, chapterXHTML: Self.longChapter)
        harness = made
        var position: ChapterHostSurface.Position?
        for _ in 0..<100 {
            position = try? await made.surface.firstVisiblePosition(in: made.webView)
            if position != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let read = try XCTUnwrap(position, "the reference line of the scroll window has text")
        let before = try await shellState(read.offset, resource: read.resource, in: made)
        let shellSnippet = String(before.split(separator: "|", omittingEmptySubsequences: false).first ?? "")

        _ = try await made.evaluate("document.documentElement.setAttribute('data-old', '1'); 'ok'")
        let target = ChapterHostPaging.restore(for: read)
        try made.surface.loadPaged(
            resource: target.resource, in: made.package, into: made.webView, geometry: .harnessFixture,
            restore: target.restore)
        for _ in 0..<100 {
            let state = try? await made.evaluate(
                "document.documentElement.hasAttribute('data-old') ? 'old' : getComputedStyle(document.documentElement).visibility")
            if state == "visible" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let onScreen = try await pagedOnScreen(read.offset, in: made)
        XCTAssertEqual(onScreen, "yes", "the text on the scroll window's reference line is on the opened page")
        let pagedSnippet = try await pagedSnippet(read.offset, in: made)
        XCTAssertEqual(pagedSnippet, shellSnippet, "both worlds count the same offset for the same text (U2)")
        XCTAssertFalse(pagedSnippet.isEmpty)
    }

    func testPagedOffsetReopensTheScrollWindowOnTheSameText() async throws {
        let made = try await ChapterHostWindowHarness.makePaged(
            in: self, resource: 2, restore: .start, chapterXHTML: Self.longChapter)
        harness = made
        for _ in 0..<100 {
            let state = try? await made.evaluate("getComputedStyle(document.documentElement).visibility")
            if state == "visible" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try await client(made, "window.qlScrollToColumn(5); return 1;")
        let value = try await client(made, "return window.qlOffsetAtCurrentColumn();")
        let offset = (value as? NSNumber)?.intValue ?? -1
        XCTAssertGreaterThan(offset, 0)
        let pagedText = try await pagedSnippet(offset, in: made)

        let target = ChapterHostPaging.toScroll(index: 2, offset: offset, count: made.package.spineURLs.count)
        guard case .position(let position) = target.restore else { return XCTFail("a position restore") }
        try made.surface.loadWindow(around: target.index, in: made.package, into: made.webView, restoring: .position(position))
        var state = ""
        for _ in 0..<100 {
            state = (try? await shellState(offset, resource: 2, in: made)) ?? ""
            if state.hasSuffix("|yes") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(state.hasSuffix("|yes"), "the first text of the page is visible in the window (\(state))")
        XCTAssertEqual(state.split(separator: "|").first.map(String.init), pagedText, "same text at the same offset")
    }
}
