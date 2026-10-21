import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 4: `loadWindow(restoring:)` lands on a position, a fraction or the chapter start, keeps
/// the shell hidden until it has, and waits for the target frame to load and be re-fitted.
@MainActor
final class ChapterHostRestoreTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func mount(
        chapters: Int = 5, around: Int = 2, restoring: ChapterHostSurface.Restore?
    ) async throws -> ChapterHostWindowHarness {
        let made = try await ChapterHostWindowHarness.make(in: self, chapters: chapters, around: around, restoring: restoring)
        harness = made
        return made
    }

    private func waitUntilVisible(_ harness: ChapterHostWindowHarness) async throws {
        for _ in 0..<100 {
            if try await harness.evaluate("getComputedStyle(document.body).visibility") == "visible" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the shell was never revealed")
    }

    func testShellHidesUntilRestoreOnlyWhenARestoreIsRequested() {
        let slot = ChapterHostShell.Slot(resource: 0, path: "/a.xhtml", byteCount: 1, estimatedHeight: 1, mounted: true)
        XCTAssertTrue(ChapterHostShell.html(slots: [slot], restore: nil).contains("body[data-hc-restore-resource] { visibility: hidden; }"))
        XCTAssertFalse(ChapterHostShell.html(slots: [slot], restore: nil).contains("data-hc-restore-resource=\""))
    }

    func testShellIsHiddenUntilRestoreAndThenRevealed() async throws {
        let harness = try await mount(restoring: .start)
        let restoreAttribute = try await harness.evaluate("document.body.hasAttribute('data-hc-restore-resource')")
        XCTAssertEqual(restoreAttribute, "1")
        try await waitUntilVisible(harness)
        let top = try await harness.evaluate("document.querySelector('div.hc-slot[data-resource=\"2\"]').getBoundingClientRect().top")
        XCTAssertEqual(Double(top) ?? 999, 0, accuracy: 2, "`.start` puts the chapter top at the window top")
    }

    func testRestoreToPositionLandsOnTheSameOffsetAsScrollTo() async throws {
        let first = try await mount(restoring: .start)
        let target = ChapterHostSurface.Position(resource: 2, offset: 300)
        try await waitUntilVisible(first)
        let scrolled = try await first.surface.scroll(to: target, in: first.webView)
        XCTAssertTrue(scrolled)
        let expectedOptional = try await first.surface.firstVisiblePosition(in: first.webView)
        let expected = try XCTUnwrap(expectedOptional)
        first.tearDown()

        let second = try await mount(restoring: .position(expected))
        try await waitUntilVisible(second)
        try await Task.sleep(nanoseconds: 300_000_000)
        let actualOptional = try await second.surface.firstVisiblePosition(in: second.webView)
        let actual = try XCTUnwrap(actualOptional)
        XCTAssertEqual(actual.resource, expected.resource)
        XCTAssertEqual(Double(actual.offset), Double(expected.offset), accuracy: 100, "within one text line")
    }

    func testRestoreFractionLandsInsideTheChapter() async throws {
        let harness = try await mount(restoring: .fraction(resource: 3, fraction: 0.5))
        try await waitUntilVisible(harness)
        try await Task.sleep(nanoseconds: 300_000_000)
        let positionOptional = try await harness.surface.firstVisiblePosition(in: harness.webView)
        let position = try XCTUnwrap(positionOptional)
        XCTAssertEqual(position.resource, 3)
        let share = try await harness.evaluate(
            """
            (function () { var r = document.querySelector('div.hc-slot[data-resource="3"]').getBoundingClientRect();
              return (window.innerHeight / 3 - r.top) / r.height; })()
            """)
        XCTAssertEqual(Double(share) ?? -1, 0.5, accuracy: 0.05)
    }

    func testRestoreLandsAfterFrameFit() async throws {
        let target = ChapterHostSurface.Position(resource: 3, offset: 1_500)
        let harness = try await mount(restoring: .position(target))
        try await waitUntilVisible(harness)
        let atOptional = try await harness.surface.firstVisiblePosition(in: harness.webView)
        let at = try XCTUnwrap(atOptional)
        try await Task.sleep(nanoseconds: 500_000_000)
        let laterOptional = try await harness.surface.firstVisiblePosition(in: harness.webView)
        let later = try XCTUnwrap(laterOptional)
        XCTAssertEqual(at.resource, 3)
        XCTAssertEqual(Double(later.offset), Double(at.offset), accuracy: 100, "no drift after the deferred re-fit")
    }

    func testRestoreOfAnUnmountedFarChapterMountsItFirst() async throws {
        let harness = try await mount(chapters: 40, around: 5, restoring: nil)
        let before = try await harness.evaluate("document.querySelector('div.hc-slot[data-resource=\"30\"] iframe') === null")
        XCTAssertEqual(before, "1", "chapter 30 starts unmounted")
        _ = try await harness.webView.callAsyncJavaScript(
            "return window.honeycrispHost.restoreTo(30, 100);", arguments: [:], in: nil, contentWorld: .defaultClient)
        var position: ChapterHostSurface.Position?
        for _ in 0..<100 {
            position = try await harness.surface.firstVisiblePosition(in: harness.webView)
            if position?.resource == 30 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(position?.resource, 30)
    }
}
