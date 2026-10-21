import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M3 pass 8, contract C2 for the host: offsets are per chapter document, counted by the page
/// script's text-node walk over `document.body`, and must equal the offsets Swift extraction produces
/// (`EPUBParser.searchResults`). The merged-document version of the parity case is an expected failure
/// (`WebKitOffsetParityTests`, decision B1); this one is not.
@MainActor
final class ChapterHostOffsetParityTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    // MARK: Parity

    private static let markers = ["ENTITY_MARKER", "UNICODE_MARKER", "WHITESPACE_MARKER", "ANCHOR_MARKER"]

    /// Well-formed counterpart of the merged fixture's marker chapter (the host serves XHTML as XML, so
    /// the unquoted attribute in the old fixture cannot be used here). Same constructs: entities, a
    /// supplementary-plane character, whitespace inside a text node, a self-closing anchor.
    private static func markerChapter(_ index: Int) -> String {
        guard index == 1 else {
            return "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>plain chapter \(index)</p></body></html>"
        }
        return """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <p>Entity &amp; &#169; ENTITY_MARKER</p>
              <p>😀UNICODE_MARKER</p>
              <p>white\n  \tWHITESPACE_MARKER</p>
              <p><a id="self-closing"/>ANCHOR_MARKER</p>
            </body></html>
            """
    }

    func testPerResourceOffsetsMatchSwiftOffsetsForEntitiesUnicodeWhitespaceAndSelfClosingAnchor() async throws {
        let harness = try await ChapterHostWindowHarness.make(
            in: self, chapters: 3, around: 1, chapterXHTML: Self.markerChapter)
        self.harness = harness
        let parser = EPUBParser()
        let swiftOffsets = try Self.markers.map { marker -> Int in
            let results = parser.searchResults(for: marker, in: harness.package)
            let result = try XCTUnwrap(results.first, "Swift finds \(marker)")
            XCTAssertEqual(result.spineIndex, 1)
            return result.characterOffset
        }

        let markerJSON = String(decoding: try JSONSerialization.data(withJSONObject: Self.markers), as: UTF8.self)
        let json = try await harness.evaluate(
            """
            (function () {
              var markers = \(markerJSON), offsets = {};
              var frame = document.querySelector('iframe[data-resource="1"]');
              var walker = frame.contentDocument.createTreeWalker(frame.contentDocument.body, NodeFilter.SHOW_TEXT, null);
              var count = 0, node;
              while ((node = walker.nextNode()) !== null) {
                markers.forEach(function (marker) {
                  var index = node.data.indexOf(marker);
                  if (offsets[marker] === undefined && index >= 0) { offsets[marker] = count + index; }
                });
                count += node.length;
              }
              return JSON.stringify(markers.map(function (marker) { return offsets[marker] === undefined ? -1 : offsets[marker]; }));
            })()
            """)
        let hostOffsets = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Int])
        XCTAssertEqual(hostOffsets, swiftOffsets, "per-chapter host offsets equal Swift extraction offsets")
    }

    // MARK: Position round trip

    /// Offset of the text node that starts with `prefix` in chapter `resource`, by an independent walk.
    private func offsetOfText(_ harness: ChapterHostWindowHarness, resource: Int, startingWith prefix: String) async throws -> Int {
        let value = try await harness.evaluate(
            """
            (function () {
              var frame = document.querySelector('iframe[data-resource="\(resource)"]');
              var walker = frame.contentDocument.createTreeWalker(frame.contentDocument.body, NodeFilter.SHOW_TEXT, null);
              var count = 0, node;
              while ((node = walker.nextNode()) !== null) {
                if (node.data.indexOf(\(String(reflecting: prefix))) === 0) { return count; }
                count += node.length;
              }
              return -1;
            })()
            """)
        return try XCTUnwrap(Int(value))
    }

    /// Column just inside the left edge of the text in chapter `resource`, in window coordinates.
    private func textLeft(_ harness: ChapterHostWindowHarness, resource: Int) async throws -> Double {
        let value = try await harness.evaluate(
            """
            (function () {
              var frame = document.querySelector('iframe[data-resource="\(resource)"]');
              var body = frame.contentDocument.body;
              var left = frame.getBoundingClientRect().left + body.getBoundingClientRect().left
                + parseFloat(frame.contentWindow.getComputedStyle(body).paddingLeft);
              return left + 1;
            })()
            """)
        return try XCTUnwrap(Double(value))
    }

    func testScrollToResourceOffsetRoundTrips() async throws {
        let harness = try await ChapterHostWindowHarness.make(in: self, chapters: 5, around: 2)
        self.harness = harness
        let column = try await textLeft(harness, resource: 2)
        for paragraph in [2, 17, 33] {
            let offset = try await offsetOfText(harness, resource: 2, startingWith: "Paragraph \(paragraph) of chapter 2.")
            XCTAssertGreaterThan(offset, 0)
            let target = ChapterHostSurface.Position(resource: 2, offset: offset)

            let scrolled = try await harness.surface.scroll(to: target, in: harness.webView)
            XCTAssertTrue(scrolled)
            let read = try await harness.surface.firstVisiblePosition(in: harness.webView, x: column)

            XCTAssertEqual(read, target, "paragraph \(paragraph): set, read back, equal")
        }
    }

    func testScrollToHandlesUnmountedChapterAndOffsetPastTheEnd() async throws {
        let harness = try await ChapterHostWindowHarness.make(in: self, chapters: 5, around: 2)
        self.harness = harness
        let missing = try await harness.surface.scroll(to: .init(resource: 0, offset: 0), in: harness.webView)
        XCTAssertFalse(missing, "chapter 0 is outside the window of 1 to 3")
        let past = try await harness.surface.scroll(to: .init(resource: 2, offset: 10_000_000), in: harness.webView)
        XCTAssertTrue(past, "an offset past the end lands on the last text node")
    }

    func testOffsetFunctionsUseTheBodyTextNodeWalkOfTheMergedScript() {
        let source = ChapterHostScript.source
        XCTAssertTrue(source.contains("createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, null)"))
        XCTAssertTrue(source.contains("count += node.length"))
        XCTAssertTrue(source.contains("offsetOfFirstVisibleText"))
        XCTAssertTrue(source.contains("scrollTo: scrollTo"))
        XCTAssertFalse(source.contains("\\("), "no interpolated data")
    }
}
