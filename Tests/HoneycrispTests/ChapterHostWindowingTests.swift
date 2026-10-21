import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 2, contract C5: the shell holds one slot per spine item and the client script mounts
/// chapters near the viewport and evicts distant ones. Pure shell and estimate checks first, then WebKit.
@MainActor
final class ChapterHostWindowingTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    // MARK: Pure

    private func slots(count: Int, mounted: Set<Int>, path: (Int) -> String = { "/Text/c\($0).xhtml" }) -> [ChapterHostShell.Slot] {
        (0..<count).map {
            ChapterHostShell.Slot(
                resource: $0, path: path($0), byteCount: 1_000, estimatedHeight: 700, mounted: mounted.contains($0))
        }
    }

    func testEstimatedHeightIsAtLeastTheViewportAndGrowsWithBytes() {
        let estimate = { (bytes: Int) in
            ChapterHostSurface.estimatedHeight(byteCount: bytes, viewportHeight: 600, pixelsPerByte: 0.3)
        }
        XCTAssertEqual(estimate(0), 600, "an empty or unknown chapter still takes a viewport")
        XCTAssertEqual(estimate(1_000), 600, "300 px is below the viewport")
        XCTAssertEqual(estimate(10_000), 3_000)
        XCTAssertGreaterThan(estimate(20_000), estimate(10_000))
        XCTAssertEqual(estimate(-5), 600, "a negative size is treated as unknown")
        XCTAssertEqual(ChapterHostSurface.estimatedHeight(byteCount: 10, viewportHeight: -1, pixelsPerByte: 0.3), 3)
    }

    func testSlotAttributesAreEscapedAndWellFormedXML() {
        let html = ChapterHostShell.html(
            slots: slots(count: 2, mounted: [0]) + [
                .init(resource: 2, path: "/Text/a&b\"<c>'.xhtml", byteCount: 5, estimatedHeight: 10, mounted: true)
            ],
            restore: .init(resource: 1, offset: 12, fraction: 0.5))
        XCTAssertFalse(html.contains("<c>"))
        XCTAssertTrue(html.contains("data-src=\"/Text/a&amp;b&quot;&lt;c&gt;&apos;.xhtml\""))
        let parser = XMLParser(data: Data(html.utf8))
        XCTAssertTrue(parser.parse(), "the shell is served as application/xhtml+xml: \(String(describing: parser.parserError))")
    }

    func testShellStillContainsNoScript() {
        let html = ChapterHostShell.html(slots: slots(count: 3, mounted: [1]), restore: nil)
        XCTAssertFalse(html.lowercased().contains("<script"), "author JavaScript is off; windowing is a client-world script")
    }

    func testRestoreAttributesAreNumericOnly() {
        let html = ChapterHostShell.html(
            slots: slots(count: 1, mounted: [0]), restore: .init(resource: 3, offset: -4, fraction: 7))
        XCTAssertTrue(html.contains("data-hc-restore-resource=\"3\""))
        XCTAssertTrue(html.contains("data-hc-restore-offset=\"0\""), "a negative offset is clamped")
        XCTAssertTrue(html.contains("data-hc-restore-fraction=\"1.0\""), "a fraction is clamped to 0...1")
        let none = ChapterHostShell.html(
            slots: slots(count: 1, mounted: [0]), restore: .init(resource: 0, offset: nil, fraction: .nan))
        XCTAssertFalse(none.contains("data-hc-restore-fraction"), "a non-finite fraction is dropped")
        // The stylesheet always names the attribute in a selector, so look at the <body> tag, not the whole document.
        XCTAssertTrue(ChapterHostShell.html(slots: slots(count: 1, mounted: [0]), restore: nil).contains("<body>"))
    }

    // MARK: WebKit

    private func mount(chapters: Int, around index: Int) async throws -> ChapterHostWindowHarness {
        let made = try await ChapterHostWindowHarness.make(in: self, chapters: chapters, around: index)
        harness = made
        return made
    }

    /// Runs `body` in the client world (where `honeycrispHost` lives) and returns its JSON result.
    private func host(_ harness: ChapterHostWindowHarness, _ body: String) async throws -> String {
        let value = try await harness.webView.callAsyncJavaScript(
            "return JSON.stringify((function () { \(body) })());", arguments: [:], in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(value as? String)
    }

    private func mounted(_ harness: ChapterHostWindowHarness) async throws -> [Int] {
        let json = try await host(harness, "return window.honeycrispHost.mountedResources();")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Int])
    }

    /// Scrolls so the top of slot `resource` is `offset` px below the top of the window, then reconciles.
    private func scroll(_ harness: ChapterHostWindowHarness, toSlot resource: Int, offset: Double = 0) async throws {
        _ = try await host(
            harness,
            """
            var slot = document.querySelector('div.hc-slot[data-resource="\(resource)"]');
            window.scrollTo(0, Math.max(0, window.scrollY + slot.getBoundingClientRect().top - \(offset)));
            return window.honeycrispHost.reconcile();
            """)
    }

    func testShellEmitsOneSlotPerSpineItemWithOnlyTheWindowMounted() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        let count = try await harness.evaluate("document.querySelectorAll('div.hc-slot').length")
        XCTAssertEqual(count, "40")
        let resources = try await harness.evaluateJSONArray(
            """
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe.hc-frame'),
              function (f) { return { resource: Number(f.getAttribute('data-resource')) }; }))
            """)
        XCTAssertEqual(resources.compactMap { $0["resource"] as? Int }, [19, 20, 21])
        let mountedNow = try await mounted(harness)
        XCTAssertEqual(mountedNow, [19, 20, 21], "the first load does not reconcile")
    }

    func testScrollingDownMountsTheNextChapterAndEvictsDistantOnes() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        let bottom = try await host(
            harness,
            """
            var slot = document.querySelector('div.hc-slot[data-resource="21"]');
            return Math.round(slot.getBoundingClientRect().bottom + window.scrollY - window.innerHeight);
            """)
        let target = try XCTUnwrap(Double(bottom))
        _ = try await host(harness, "window.scrollTo(0, \(target)); return window.honeycrispHost.reconcile();")
        let after = try await mounted(harness)
        XCTAssertTrue(after.contains(22), "the chapter below the viewport mounts: \(after)")
        XCTAssertFalse(after.contains(19), "chapter 19 is far above the viewport and is evicted: \(after)")
        XCTAssertLessThanOrEqual(after.count, 5)
    }

    func testChapterIntersectingTheViewportIsNeverEvicted() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        for step in 0..<50 {
            let covered = try await host(
                harness,
                """
                window.scrollBy(0, 480);
                window.honeycrispHost.reconcile();
                var y = Math.round(window.innerHeight / 3), ok = false, count = 0;
                Array.prototype.forEach.call(document.querySelectorAll('div.hc-slot'), function (s) {
                  var r = s.getBoundingClientRect();
                  if (s.querySelector('iframe.hc-frame')) { count += 1; }
                  if (y >= r.top && y < r.bottom && s.querySelector('iframe.hc-frame')) { ok = true; }
                });
                return { ok: ok, count: count };
                """)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(covered.utf8)) as? [String: Any])
            XCTAssertEqual(decoded["ok"] as? Bool, true, "step \(step): the chapter on the reference line is mounted")
            XCTAssertLessThanOrEqual(decoded["count"] as? Int ?? 99, 5, "step \(step)")
        }
    }

    func testEvictedSlotKeepsItsHeight() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        let before = try await host(
            harness,
            "return Math.round(document.querySelector('div.hc-slot[data-resource=\"19\"]').getBoundingClientRect().height);")
        try await scroll(harness, toSlot: 25)
        let mountedNow = try await mounted(harness)
        XCTAssertFalse(mountedNow.contains(19), "chapter 19 was evicted: \(mountedNow)")
        let after = try await host(
            harness,
            "return Math.round(document.querySelector('div.hc-slot[data-resource=\"19\"]').getBoundingClientRect().height);")
        XCTAssertEqual(Double(after) ?? -1, Double(before) ?? -2, accuracy: 1, "the evicted slot keeps its measured height")
        XCTAssertGreaterThan(Double(after) ?? 0, 0)
    }

    func testReconcileSettlesWithinThreePasses() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        try await scroll(harness, toSlot: 24, offset: 100)
        // Newly mounted frames load and are measured asynchronously, and each measurement can move the slots
        // below it. Forced passes taken while frames are still loading chase that layout, not the hysteresis
        // this test is about, so every pass starts from a quiescent page.
        try await waitUntilQuiescent(harness)
        var seen: [[Int]] = []
        for _ in 0..<3 {
            _ = try await host(harness, "return window.honeycrispHost.reconcile();")
            try await waitUntilQuiescent(harness)
            seen.append(try await mounted(harness))
        }
        XCTAssertEqual(seen[1], seen[2], "the mounted set is stable after the first forced passes: \(seen)")
        XCTAssertEqual(seen[0], seen[2], "and already settled after one: \(seen)")
    }

    // MARK: Heights and prepend (pass 3)

    private func pause(_ milliseconds: UInt64) async throws { try await Task.sleep(nanoseconds: milliseconds * 1_000_000) }

    /// Polls the page until `condition` (a JS expression) is truthy; fails after 10 s.
    private func waitUntil(_ harness: ChapterHostWindowHarness, _ condition: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if try await harness.evaluate("(\(condition)) ? 'yes' : 'no'") == "yes" { return }
            try await pause(100)
        }
        XCTFail("timed out waiting for \(condition)", file: file, line: line)
    }

    /// Waits until every mounted frame is ready and the document height has not changed for 300 ms.
    private func waitUntilQuiescent(_ harness: ChapterHostWindowHarness, file: StaticString = #filePath, line: UInt = #line) async throws {
        var stableSince = 0
        var lastHeight = ""
        for _ in 0..<100 {
            let state = try await harness.evaluate(
                """
                (function () {
                  var frames = document.querySelectorAll('iframe.hc-frame'), ready = true;
                  Array.prototype.forEach.call(frames, function (f) { if (f.getAttribute('data-hc-ready') !== '1') { ready = false; } });
                  return (ready ? 'ready:' : 'loading:') + document.documentElement.scrollHeight + ':' + Math.round(window.scrollY);
                })()
                """)
            if state.hasPrefix("ready:"), state == lastHeight { stableSince += 1 } else { stableSince = 0 }
            lastHeight = state
            if stableSince >= 3 { return }
            try await pause(100)
        }
        XCTFail("the page never became quiescent", file: file, line: line)
    }

    private func probeTop(_ harness: ChapterHostWindowHarness, resource: Int) async throws -> Double {
        let value = try await harness.evaluate(
            """
            (function () {
              var f = document.querySelector('iframe[data-resource="\(resource)"]');
              return f.getBoundingClientRect().top + f.contentDocument.getElementById('probe').getBoundingClientRect().top;
            })()
            """)
        return try XCTUnwrap(Double(value))
    }

    func testPrependingAChapterAboveTheViewportDoesNotMoveVisibleText() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        // Chapter 19's probe near the top of the window; chapter 18 lies fully above and was never mounted.
        try await scroll(harness, toSlot: 19, offset: -50)
        let mountedNow = try await mounted(harness)
        XCTAssertTrue(mountedNow.contains(18), "chapter 18 mounted above the viewport: \(mountedNow)")
        let estimate = try await harness.evaluate("document.querySelector('div.hc-slot[data-resource=\"18\"]').getBoundingClientRect().height")
        let before = try await probeTop(harness, resource: 19)
        try await waitUntil(harness, "document.querySelector('div.hc-slot[data-resource=\"18\"]').hasAttribute('data-hc-measured')")
        try await pause(300)
        let after = try await probeTop(harness, resource: 19)
        let measured = try await harness.evaluate("document.querySelector('div.hc-slot[data-resource=\"18\"]').getBoundingClientRect().height")
        XCTAssertNotEqual(Double(measured) ?? 0, Double(estimate) ?? 0, "the measurement changed the height, so the test means something")
        XCTAssertEqual(after, before, accuracy: 1, "visible text did not move when chapter 18 was measured above it")
    }

    func testMeasuredHeightReplacesEstimateAndUpdatesRatio() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        let report = try await host(
            harness,
            """
            var s = document.querySelector('div.hc-slot[data-resource="20"]'), f = s.querySelector('iframe.hc-frame');
            var far = document.querySelector('div.hc-slot[data-resource="5"]');
            return { measured: s.getAttribute('data-hc-measured'), slot: Math.round(s.getBoundingClientRect().height),
                     frame: Math.round(f.getBoundingClientRect().height), ratio: window.honeycrispHost.pixelsPerByte(),
                     bytes: Number(far.getAttribute('data-bytes')), far: Math.round(far.getBoundingClientRect().height),
                     vh: window.innerHeight };
            """)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["slot"] as? Int, decoded["frame"] as? Int, "the slot takes the measured height")
        XCTAssertNotNil(decoded["measured"] as? String)
        let ratio = try XCTUnwrap(decoded["ratio"] as? Double)
        XCTAssertGreaterThan(ratio, 0)
        let expected = max(Double(decoded["vh"] as? Int ?? 0), Double(decoded["bytes"] as? Int ?? 0) * ratio)
        XCTAssertEqual(Double(decoded["far"] as? Int ?? -1), expected, accuracy: 1, "an unmeasured slot uses the running ratio")
    }

    func testScrollAcrossTwentyChapterBoundariesHasNoJump() async throws {
        let harness = try await mount(chapters: 25, around: 0)
        var lines: [String] = []
        var maxMounted = 0, mounts = 0, evictions = 0, boundaries = 0
        var previousMounted = try await mounted(harness)
        func position() async throws -> (Int, Int)? {
            let json = try await host(harness, "return window.honeycrispHost.offsetOfFirstVisibleText();")
            // `null` (no text on the reference line yet) is a JSON fragment; JSONSerialization rejects it by default.
            if json == "null" { return nil }
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int],
                let resource = object["resource"], let offset = object["offset"] else { return nil }
            return (resource, offset)
        }
        for direction in [1.0, -1.0] {
            var last: (Int, Int)?
            for step in 0..<400 {
                _ = try await host(harness, "window.scrollBy(0, \(direction * 480)); return window.honeycrispHost.reconcile();")
                try await pause(30)
                let now = try await mounted(harness)
                maxMounted = max(maxMounted, now.count)
                mounts += Set(now).subtracting(previousMounted).count
                evictions += Set(previousMounted).subtracting(now).count
                previousMounted = now
                guard let current = try await position() else { continue }
                if let last {
                    if current.0 != last.0 { boundaries += 1 }
                    let ordered = direction > 0 ? (current >= last) : (current <= last)
                    XCTAssertTrue(ordered, "step \(step) direction \(direction): \(last) then \(current)")
                }
                last = current
            }
        }
        lines += ["steps: 800", "boundaries crossed: \(boundaries)", "mounts: \(mounts)", "evictions: \(evictions)", "max mounted: \(maxMounted)"]
        try TestDiagnostics.write("m4-scroll-boundaries.txt", lines: lines)
        XCTAssertLessThanOrEqual(maxMounted, 5)
        XCTAssertGreaterThanOrEqual(boundaries, 20, "the walk crossed at least 20 chapter boundaries")
    }

    func testCosmeticPatchKeepsVisibleTextStationary() async throws {
        let harness = try await mount(chapters: 40, around: 20)
        try await scroll(harness, toSlot: 20, offset: 0)
        try await waitUntil(harness, "document.querySelector('div.hc-slot[data-resource=\"19\"]').hasAttribute('data-hc-measured')")
        let slotTop = "document.querySelector('div.hc-slot[data-resource=\"20\"]').getBoundingClientRect().top"
        let heightAbove = "document.querySelector('div.hc-slot[data-resource=\"19\"]').getBoundingClientRect().height"
        let beforeText = try await harness.evaluate(slotTop)
        let before = try XCTUnwrap(Double(beforeText))
        let oldHeightText = try await harness.evaluate(heightAbove)
        let oldHeight = try XCTUnwrap(Double(oldHeightText))
        var bigger = ReaderCosmeticSettings.chapterHostFixture
        bigger.fontSizePercent = 150
        try await harness.surface.applyCosmetics(bigger, to: harness.webView)
        try await pause(400)
        let newHeightText = try await harness.evaluate(heightAbove)
        let newHeight = try XCTUnwrap(Double(newHeightText))
        let afterText = try await harness.evaluate(slotTop)
        let after = try XCTUnwrap(Double(afterText))
        XCTAssertGreaterThan(newHeight, oldHeight, "the chapter above grew")
        XCTAssertEqual(after, before, accuracy: 1, "the chapter under the viewport did not move")
    }
}
