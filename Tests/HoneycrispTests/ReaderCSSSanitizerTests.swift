import Foundation
import XCTest
@testable import Honeycrisp

final class ReaderCSSSanitizerTests: XCTestCase {
    private let fallback = "#123456"

    // MARK: Colors

    func testHexColorNormalizesSixAndThreeDigitForms() {
        XCTAssertEqual(ReaderCSSSanitizer.hexColor("#FFFFFF", fallback: fallback), "#ffffff")
        XCTAssertEqual(ReaderCSSSanitizer.hexColor("0068DA", fallback: fallback), "#0068da")
        XCTAssertEqual(ReaderCSSSanitizer.hexColor("  #1c1c1e \n", fallback: fallback), "#1c1c1e")
        XCTAssertEqual(ReaderCSSSanitizer.hexColor("#fA3", fallback: fallback), "#ffaa33")
    }

    func testHexColorRejectsInjectionAndUnsupportedForms() {
        let bad = [
            "#fff;}body{display:none",
            "</style><script>alert(1)</script>",
            "red",
            "rgb(0,0,0)",
            "#ffff",
            "#fffffff",
            "#12345g",
            "#ffffffff",
            "",
            "#",
            "\u{FF11}\u{FF12}\u{FF13}",
        ]
        for value in bad {
            XCTAssertEqual(ReaderCSSSanitizer.hexColor(value, fallback: fallback), fallback, "value: \(value)")
        }
    }

    func testSeededThemeColorsAreUnchanged() {
        for theme in SettingsManager.seedThemes {
            for set in [theme.light, theme.dark] {
                for value in [set.background, set.text, set.link] {
                    XCTAssertEqual(ReaderCSSSanitizer.hexColor(value, fallback: fallback), value.lowercased(), theme.name)
                }
            }
        }
    }

    // MARK: Font family

    func testEveryPresetStackRoundTripsExactly() {
        for preset in FontPresets.all {
            XCTAssertEqual(ReaderCSSSanitizer.fontFamily(preset.cssStack, fallback: "x"), preset.cssStack, preset.id)
        }
    }

    func testCustomFamiliesAreAccepted() {
        let accepted = [
            "Georgia, serif",
            "'Hiragino Mincho ProN', serif",
            "\"Source Serif 4\", Georgia, serif",
            "'AvenirNext-Regular', sans-serif",
            "Fira_Code.Retina",
            "  Georgia  ",
        ]
        for value in accepted {
            XCTAssertEqual(
                ReaderCSSSanitizer.fontFamily(value, fallback: "x"),
                value.trimmingCharacters(in: .whitespaces),
                "value: \(value)"
            )
        }
    }

    func testFontFamilyInjectionAndMalformedValuesFallBack() {
        let bad = [
            "Georgia;}body{display:none",
            "Georgia} body {",
            "</style><script>alert(1)</script>",
            "url(https://example.com/x.woff)",
            "Georgia, url(x)",
            "Geor\\gia",
            "'Georgia",
            "Georgia'",
            "'Georgia\", serif",
            "Georgia,, serif",
            "Georgia,",
            "''",
            "'",
            "1Georgia",
            "",
            "   ",
        ]
        for value in bad {
            XCTAssertEqual(ReaderCSSSanitizer.fontFamily(value, fallback: "x"), "x", "value: \(value)")
        }
    }

    func testFontFamilyLengthLimits() {
        let ok = String(repeating: "a", count: ReaderCSSSanitizer.maxFontNameLength)
        let tooLong = String(repeating: "a", count: ReaderCSSSanitizer.maxFontNameLength + 1)
        XCTAssertEqual(ReaderCSSSanitizer.fontFamily(ok, fallback: "x"), ok)
        XCTAssertEqual(ReaderCSSSanitizer.fontFamily(tooLong, fallback: "x"), "x")
        XCTAssertEqual(ReaderCSSSanitizer.fontFamily("'\(tooLong)'", fallback: "x"), "x")

        let manyNames = Array(repeating: "Georgia", count: 40).joined(separator: ", ")
        XCTAssertGreaterThan(manyNames.count, ReaderCSSSanitizer.maxFontFamilyLength)
        XCTAssertEqual(ReaderCSSSanitizer.fontFamily(manyNames, fallback: "x"), "x")
    }

    func testFontFamilyDefaultFallbackIsTheDefaultStack() {
        XCTAssertEqual(ReaderCSSSanitizer.fontFamily("a;b"), FontPresets.defaultStack)
    }

    // MARK: Numbers

    func testNumericClampsMatchSettingsManagerRanges() {
        XCTAssertEqual(ReaderCSSSanitizer.fontSizePercent(10), 50)
        XCTAssertEqual(ReaderCSSSanitizer.fontSizePercent(1000), 300)
        XCTAssertEqual(ReaderCSSSanitizer.fontSizePercent(120), 120)
        XCTAssertEqual(ReaderCSSSanitizer.maxWidth(0), 320)
        XCTAssertEqual(ReaderCSSSanitizer.maxWidth(99999), 1400)
        XCTAssertEqual(ReaderCSSSanitizer.paddingH(-5), 0)
        XCTAssertEqual(ReaderCSSSanitizer.paddingH(500), 120)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(0.1), 1.2)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(9), 2.4)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(1.6), 1.6)
    }

    func testNonFiniteLineHeightFallsBackToDefault() {
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(.nan), 1.6)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(.infinity), 1.6)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(-.infinity), 1.6)
    }
}
