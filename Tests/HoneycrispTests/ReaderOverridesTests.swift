import Foundation
import XCTest
@testable import Honeycrisp

final class ReaderOverridesTests: XCTestCase {
    func testDefaultIsEmptyAndNilFieldsAreOmittedFromJSON() throws {
        XCTAssertEqual(ReaderOverrides.none, ReaderOverrides())
        var overrides = ReaderOverrides()
        overrides.fontSizePercent = 120
        let json = String(decoding: try JSONEncoder().encode(overrides), as: UTF8.self)
        XCTAssertTrue(json.contains("fontSizePercent"))
        XCTAssertFalse(json.contains("lineHeight"))
        XCTAssertFalse(json.contains("bodyFont"))
    }

    func testCodableRoundTrip() throws {
        var overrides = ReaderOverrides()
        overrides.bodyFont = "Georgia, serif"
        overrides.fontSizePercent = 130
        overrides.lineHeight = 1.8
        overrides.maxWidth = 640
        overrides.paddingH = 10
        overrides.paddingV = 12
        overrides.paragraphIndent = 1
        overrides.paragraphSpacing = 0.25
        overrides.justify = true
        overrides.hyphenate = true
        overrides.light = ModeColors(background: "#101010", ink: "#eeeeee", link: "#88aaff")
        overrides.dark.background = "#000000"
        let decoded = try JSONDecoder().decode(ReaderOverrides.self, from: try JSONEncoder().encode(overrides))
        XCTAssertEqual(decoded, overrides)
    }

    func testDecodingToleratesMissingFields() throws {
        let decoded = try JSONDecoder().decode(ReaderOverrides.self, from: Data(#"{"fontSizePercent":115}"#.utf8))
        XCTAssertEqual(decoded.fontSizePercent, 115)
        XCTAssertNil(decoded.lineHeight)
        XCTAssertTrue(decoded.light.isEmpty)
        XCTAssertTrue(decoded.dark.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(ReaderOverrides.self, from: Data("{}".utf8)), .none)
    }

    func testSanitizedClampsEveryNumber() {
        var overrides = ReaderOverrides()
        overrides.fontSizePercent = 9999
        overrides.lineHeight = .infinity
        overrides.maxWidth = 5
        overrides.paddingH = -5
        overrides.paddingV = 500
        overrides.paragraphIndent = 99
        overrides.paragraphSpacing = .nan
        let clean = overrides.sanitized()
        XCTAssertEqual(clean.fontSizePercent, 300)
        XCTAssertEqual(clean.lineHeight, 1.6)
        XCTAssertEqual(clean.maxWidth, 320)
        XCTAssertEqual(clean.paddingH, 0)
        XCTAssertEqual(clean.paddingV, 120)
        XCTAssertEqual(clean.paragraphIndent, 3)
        XCTAssertEqual(clean.paragraphSpacing, 0)
    }

    func testSanitizedDropsInvalidFontsAndColorsAndNormalizesValidOnes() {
        var overrides = ReaderOverrides()
        overrides.bodyFont = "a{b}"
        overrides.headingFont = "   "
        overrides.monospaceFont = FontPresets.all[2].cssStack
        overrides.light = ModeColors(background: "red", ink: "#FFF", link: "rgb(0,0,0)")
        let clean = overrides.sanitized()
        XCTAssertNil(clean.bodyFont)
        XCTAssertNil(clean.headingFont)
        XCTAssertEqual(clean.monospaceFont, FontPresets.all[2].cssStack)
        XCTAssertNil(clean.light.background)
        XCTAssertEqual(clean.light.ink, "#ffffff")
        XCTAssertNil(clean.light.link)
    }

    func testGeometryDetection() {
        var changed = ReaderOverrides()
        changed.maxWidth = 600
        XCTAssertTrue(changed.changesGeometry(from: .none))
        var cosmetic = ReaderOverrides()
        cosmetic.lineHeight = 2
        XCTAssertFalse(cosmetic.changesGeometry(from: .none))
        XCTAssertFalse(changed.changesGeometry(from: changed))
    }

    func testModeColorsSelection() {
        var overrides = ReaderOverrides()
        overrides.light.background = "#111111"
        overrides.dark.background = "#222222"
        XCTAssertEqual(overrides.colors(isDark: false).background, "#111111")
        XCTAssertEqual(overrides.colors(isDark: true).background, "#222222")
        XCTAssertTrue(ModeColors().isEmpty)
        XCTAssertFalse(overrides.light.isEmpty)
    }
}
