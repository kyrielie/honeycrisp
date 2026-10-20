import Foundation
import XCTest
@testable import Honeycrisp

/// `Family` in a theme's Info.plist is a grouping name (NNW convention), never a CSS font stack.
final class FamilyHandlingTests: XCTestCase {
    private func writeTheme(family: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("family-\(UUID().uuidString).nnwtheme", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var plist: [String: Any] = ["ThemeIdentifier": "test.family.\(UUID().uuidString)", "Name": "Family Fixture"]
        if let family { plist["Family"] = family }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        try #":root{--nnw-bg:#fff;--nnw-ink:#000;--nnw-link:#06c;}"#
            .write(to: directory.appendingPathComponent("stylesheet.css"), atomically: true, encoding: .utf8)
        try #"<div id="bodyContainer" class="articleBody">[[title]][[body]]</div>"#
            .write(to: directory.appendingPathComponent("template.html"), atomically: true, encoding: .utf8)
        return directory
    }

    private func cosmetics() -> ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: 100,
            fontFamily: "serif",
            backgroundCSS: "#ffffff",
            textCSS: "#000000",
            linkCSS: "#0068da",
            hitBackground: "#ffee58",
            hitText: "#000000",
            hitActiveBackground: "#ff9800",
            hitActiveText: "#000000",
            lineHeight: 1.5,
            maxWidth: 700,
            paddingH: 24,
            paddingV: 24,
            paragraphIndent: 0.3,
            paragraphSpacing: 0.5,
            justify: false,
            hyphenate: false,
            allowLinkClicks: true
        )
    }

    func testFamilyIsKeptAsGroupNameAndNeverEmittedAsCSS() throws {
        let skin = try SkinLoader.load(directory: try writeTheme(family: "Constructivist"))
        XCTAssertEqual(skin.familyGroup, "Constructivist")
        let css = EPUBParser.readerOverrideCSS(cosmetics(), skin: skin)
        XCTAssertFalse(css.contains("Constructivist"))
        XCTAssertTrue(css.contains("font-family: serif"))
    }

    func testHostileFamilyNeverReachesGeneratedCSS() throws {
        let hostile = "}</style><script>alert(1)</script>"
        let skin = try SkinLoader.load(directory: try writeTheme(family: hostile))
        let css = EPUBParser.readerOverrideCSS(cosmetics(), skin: skin)
        XCTAssertFalse(css.contains("alert(1)"))
        XCTAssertFalse(css.lowercased().contains("</style"))
    }

    func testMissingFamilyIsNil() throws {
        let skin = try SkinLoader.load(directory: try writeTheme(family: nil))
        XCTAssertNil(skin.familyGroup)
    }

    func testGroupNameSanitizing() {
        XCTAssertNil(SkinLoader.sanitizedGroupName(nil))
        XCTAssertNil(SkinLoader.sanitizedGroupName("   \n\t "))
        XCTAssertEqual(SkinLoader.sanitizedGroupName("  Quiet\u{0007}Room \n"), "QuietRoom")
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(SkinLoader.sanitizedGroupName(long)?.count, 128)
    }

    func testBundledThemesCarryNoFamilyThatCouldBecomeAFont() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("Sources/Skins/Bundled", isDirectory: true)
        for name in ["Original", "Quiet", "Paper", "Fimfiction"] {
            let skin = try SkinLoader.load(directory: root.appendingPathComponent(name + ".nnwtheme", isDirectory: true))
            let css = EPUBParser.readerOverrideCSS(cosmetics(), skin: skin)
            if let group = skin.familyGroup { XCTAssertFalse(css.contains(group), name) }
        }
    }
}
