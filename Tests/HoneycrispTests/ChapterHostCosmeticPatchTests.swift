import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

/// Roadmap M3 pass 7, contract C8: a cosmetic change reaches every mounted chapter without a reload.
@MainActor
final class ChapterHostCosmeticPatchTests: XCTestCase {
    private var harness: ChapterHostWindowHarness?

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func changed(_ base: ReaderCosmeticSettings = .chapterHostFixture) -> ReaderCosmeticSettings {
        var cosmetics = base
        cosmetics.textCSS = "#102030"
        cosmetics.backgroundCSS = "#fafafa"
        cosmetics.fontSizePercent = 150
        return cosmetics
    }

    private struct FrameStyle {
        let resource: Int
        let color: String
        let fontSize: Double
        let textAlign: String
        let height: Double
        let marker: String
    }

    private func styles(_ harness: ChapterHostWindowHarness) async throws -> [FrameStyle] {
        let objects = try await harness.evaluateJSONArray(
            """
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe.hc-frame'), function (f) {
              var p = f.contentDocument.getElementById('probe');
              var s = f.contentWindow.getComputedStyle(p);
              return { resource: Number(f.getAttribute('data-resource')), color: s.color,
                       fontSize: parseFloat(s.fontSize), textAlign: s.textAlign,
                       height: f.getBoundingClientRect().height,
                       marker: String(f.contentWindow.__hcMarker) };
            }))
            """)
        return objects.map {
            FrameStyle(
                resource: ($0["resource"] as? Int) ?? -1, color: ($0["color"] as? String) ?? "",
                fontSize: ($0["fontSize"] as? Double) ?? 0, textAlign: ($0["textAlign"] as? String) ?? "",
                height: ($0["height"] as? Double) ?? 0, marker: ($0["marker"] as? String) ?? "")
        }
    }

    private func mount() async throws -> ChapterHostWindowHarness {
        let made = try await ChapterHostWindowHarness.make(in: self)
        harness = made
        return made
    }

    func testCosmeticPatchUpdatesAllMountedChaptersWithoutReload() async throws {
        let harness = try await mount()
        _ = try await harness.evaluate(
            "Array.prototype.forEach.call(document.querySelectorAll('iframe.hc-frame'), function (f) { f.contentWindow.__hcMarker = 'kept'; }); 'ok'")
        let before = try await styles(harness)
        XCTAssertEqual(before.map(\.resource), [1, 2, 3])
        XCTAssertTrue(before.allSatisfy { $0.color == "rgb(0, 0, 0)" }, "user text color beats the book's p color")
        let commitsBefore = harness.commitCount

        let patched = try await harness.surface.applyCosmetics(changed(), to: harness.webView)

        XCTAssertEqual(patched, 3)
        XCTAssertEqual(harness.commitCount, commitsBefore, "no navigation: the shell was not reloaded")
        let after = try await styles(harness)
        XCTAssertEqual(after.map(\.resource), [1, 2, 3])
        for (old, new) in zip(before, after) {
            XCTAssertEqual(new.color, "rgb(16, 32, 48)", "frame \(new.resource) color")
            XCTAssertGreaterThan(new.fontSize, old.fontSize, "frame \(new.resource) font size")
            XCTAssertEqual(new.marker, "kept", "frame \(new.resource) document was not reloaded")
        }
    }

    func testFramesAreResizedAfterPatchInBothDirections() async throws {
        let harness = try await mount()
        let original = try await styles(harness).map(\.height)
        XCTAssertTrue(original.allSatisfy { $0 > 0 })

        try await harness.surface.applyCosmetics(changed(), to: harness.webView)
        let larger = try await styles(harness).map(\.height)
        for (old, new) in zip(original, larger) { XCTAssertGreaterThan(new, old) }

        try await harness.surface.applyCosmetics(.chapterHostFixture, to: harness.webView)
        let restored = try await styles(harness).map(\.height)
        for (old, new) in zip(original, restored) {
            XCTAssertEqual(new, old, accuracy: 2, "a shorter chapter shrinks its frame again")
        }
    }

    func testPatchAddsAndRemovesOptionalRules() async throws {
        let harness = try await mount()
        var justified = ReaderCosmeticSettings.chapterHostFixture
        justified.textAlignment = .justify

        try await harness.surface.applyCosmetics(justified, to: harness.webView)
        let on = try await styles(harness)
        XCTAssertTrue(on.allSatisfy { $0.textAlign == "justify" }, "optional alignment rule appeared")

        try await harness.surface.applyCosmetics(.chapterHostFixture, to: harness.webView)
        let off = try await styles(harness)
        XCTAssertTrue(off.allSatisfy { $0.textAlign != "justify" }, "and disappeared again: \(off.map(\.textAlign))")
    }

    func testPatchPayloadWithClosingStyleTagStaysInert() async throws {
        let harness = try await mount()
        let hostile = "p { color: #00aa00; }</style><script>window.__pwn = 1;</script><style>"
        let result = try await harness.webView.callAsyncJavaScript(
            "return window.honeycrispHost.applyUserCSS(css);", arguments: ["css": hostile], in: nil,
            contentWorld: .defaultClient)
        XCTAssertEqual((result as? NSNumber)?.intValue, 3)

        let objects = try await harness.evaluateJSONArray(
            """
            JSON.stringify(Array.prototype.map.call(document.querySelectorAll('iframe.hc-frame'), function (f) {
              var d = f.contentDocument;
              var style = d.getElementById('honeycrisp-user');
              return { text: style.textContent, children: style.children.length,
                       scripts: d.querySelectorAll('script').length, pwn: String(f.contentWindow.__pwn) };
            }))
            """)
        XCTAssertEqual(objects.count, 3)
        for object in objects {
            XCTAssertEqual(object["text"] as? String, hostile, "stored as text, byte for byte")
            XCTAssertEqual(object["children"] as? Int, 0)
            XCTAssertEqual(object["scripts"] as? Int, 0)
            XCTAssertEqual(object["pwn"] as? String, "undefined")
        }
    }

    func testChaptersServedLaterCarryThePatchedCosmetics() async throws {
        let harness = try await mount()
        try await harness.surface.applyCosmetics(changed(), to: harness.webView)
        let transform = try XCTUnwrap(harness.surface.schemeHandler.transform)
        let output = String(decoding: transform(Data("<html><head></head><body></body></html>".utf8)), as: UTF8.self)
        XCTAssertTrue(output.contains("--reader-text: #102030;"))
        XCTAssertTrue(output.contains("--reader-bg: #fafafa;"))
        XCTAssertFalse(output.contains("--reader-bg: #ffffff;"), "the earlier cosmetics are gone")
        XCTAssertTrue(output.contains("lang=\"en\""), "the attached package language is kept")
    }

    func testPatchFunctionIsStaticAndTargetsTheServedStyleID() {
        let source = ChapterHostScript.source
        XCTAssertTrue(source.contains("applyUserCSS"))
        XCTAssertTrue(source.contains("'\(ServedChapter.userStyleID)'"), "script and ServedChapter agree on the id")
        XCTAssertTrue(source.contains("style.textContent = css"), "CSS is only ever assigned as text")
        XCTAssertFalse(source.contains("innerHTML"))
    }
}
