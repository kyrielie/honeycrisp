import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Investigation probe for the two open host failures (`testFramesAreResizedAfterPatchInBothDirections`,
/// `testScrollToResourceOffsetRoundTrips`). Both fit one cause: a frame is shorter than its chapter, so
/// content below the frame's bottom edge is clipped and `scrollTo` lands in the next frame.
///
/// The test asserts the invariant (no mounted chapter's last paragraph lies below its frame's bottom
/// edge) at the moment the other tests read, and writes per-frame measurements at later moments to
/// `build/diagnostics/frame-fit-probe.txt` so the timeline shows when, and whether, the frame settles.
/// Remove this file once the cause is fixed and the invariant lives in `ChapterHostShellTests`.
@MainActor
final class ChapterHostFrameFitProbeTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private static let frameScript = """
        JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe.hc-frame'), function (f) {
          var d = f.contentDocument, r = d.documentElement, b = d.body;
          var ps = d.getElementsByTagName('p'), last = ps[ps.length - 1], probe = d.getElementById('probe');
          var cs = probe ? f.contentWindow.getComputedStyle(probe) : null;
          return {
            resource: Number(f.getAttribute('data-resource')),
            styleHeight: f.style.height, clientHeight: f.clientHeight, clientWidth: f.clientWidth,
            hcHeight: f.getAttribute('data-hc-height'), hcError: f.getAttribute('data-hc-error'),
            readyState: d.readyState, compatMode: d.compatMode, sheets: d.styleSheets.length,
            rootScrollHeight: r.scrollHeight, bodyScrollHeight: b ? b.scrollHeight : -1,
            rootOffsetHeight: r.offsetHeight, bodyOffsetHeight: b ? b.offsetHeight : -1,
            lastBottom: last ? Math.round(last.getBoundingClientRect().bottom + f.contentWindow.scrollY) : -1,
            probeFontSize: cs ? cs.fontSize : '', probeLineHeight: cs ? cs.lineHeight : '',
            probeMarginBottom: cs ? cs.marginBottom : '', paragraphs: ps.length
          };
        }))
        """

    private static let outerScript = """
        JSON.stringify({ innerWidth: window.innerWidth, innerHeight: window.innerHeight,
          clientWidth: document.documentElement.clientWidth, clientHeight: document.documentElement.clientHeight,
          scrollHeight: document.documentElement.scrollHeight, compatMode: document.compatMode,
          contentType: document.contentType })
        """

    private func sample(_ harness: ChapterHostWindowHarness, label: String, since start: Date) async throws
        -> (lines: [String], clipped: [Int])
    {
        let frames = try await harness.evaluateJSONArray(Self.frameScript)
        let outer = try await harness.evaluate(Self.outerScript)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        var lines = ["[\(label) +\(ms)ms] outer \(outer)"]
        var clipped: [Int] = []
        for frame in frames {
            let fields = frame.keys.sorted().map { "\($0)=\(frame[$0] ?? "")" }.joined(separator: " ")
            lines.append("  \(fields)")
            let bottom = (frame["lastBottom"] as? Double) ?? 0
            let height = (frame["clientHeight"] as? Double) ?? 0
            if bottom > height + 1 { clipped.append((frame["resource"] as? Int) ?? -1) }
        }
        return (lines, clipped)
    }

    func testNoChapterContentIsClippedByItsFrame() async throws {
        let started = Date()
        let harness = try await ChapterHostWindowHarness.make(in: self, chapters: 5, around: 2)
        self.harness = harness

        var lines = [
            "scrollerStyle=\(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay")",
            "Expected by CSS arithmetic (unverified): frames 1,2,3 about 1123, 1809, 2496 px",
        ]
        let atRead = try await sample(harness, label: "t0 (when the other tests read)", since: started)
        lines += atRead.lines

        var elapsed: UInt64 = 0
        for target: UInt64 in [50, 100, 250, 500, 1000, 2000] {
            try await Task.sleep(nanoseconds: (target - elapsed) * 1_000_000)
            elapsed = target
            lines += try await sample(harness, label: "after wait", since: started).lines
        }

        let fitLog = try await harness.webView.callAsyncJavaScript(
            "return JSON.stringify(window.honeycrispHost.fitLog);", arguments: [:], in: nil,
            contentWorld: .defaultClient)
        lines.append("fitLog before the explicit fitAll (one JSON entry per fit call):")
        lines += String(describing: fitLog ?? "none").components(separatedBy: "},{").map { "  \($0)" }
        _ = try await harness.webView.callAsyncJavaScript(
            "window.honeycrispHost.fitAll('probe'); return 1;", arguments: [:], in: nil, contentWorld: .defaultClient)
        let refit = try await sample(harness, label: "after fitAll()", since: started)
        lines += refit.lines
        lines.append("clipped at t0: \(atRead.clipped); clipped after fitAll: \(refit.clipped)")
        try TestDiagnostics.write("frame-fit-probe.txt", lines: lines)

        XCTAssertEqual(atRead.clipped, [], "frames whose last paragraph lies below the frame's bottom edge at t0")
    }
}
