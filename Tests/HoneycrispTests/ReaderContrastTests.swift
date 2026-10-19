import Foundation
import XCTest
@testable import Honeycrisp

final class ReaderContrastTests: XCTestCase {
    // MARK: Math

    func testRatioKnownPairs() {
        XCTAssertEqual(ReaderContrast.ratio("#000000", "#ffffff"), 21.0, accuracy: 0.01)
        XCTAssertEqual(ReaderContrast.ratio("#ffffff", "#000000"), 21.0, accuracy: 0.01)
        XCTAssertEqual(ReaderContrast.ratio("#000000", "#000000"), 1.0, accuracy: 0.001)
    }

    func testRatiosAgainstTheOldFixedYellowHit() {
        // The values that motivated this change (hit background #FFEE58).
        XCTAssertEqual(ReaderContrast.ratio("#E5E5EA", "#FFEE58"), 1.05, accuracy: 0.01)
        XCTAssertEqual(ReaderContrast.ratio("#ffffff", "#FFEE58"), 1.19, accuracy: 0.01)
        XCTAssertEqual(ReaderContrast.ratio("#1A1A1A", "#FFEE58"), 14.61, accuracy: 0.01)
        XCTAssertEqual(ReaderContrast.ratio("#000000", "#FFEE58"), 17.62, accuracy: 0.01)
        XCTAssertEqual(ReaderContrast.ratio("#FFEE58", "#FFFDF6"), 1.17, accuracy: 0.01)
    }

    func testParsingAcceptsHexWithOrWithoutHashAndReadsAnythingElseAsBlack() {
        XCTAssertEqual(ReaderContrast.relativeLuminance(ofCSS: "ffffff"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ReaderContrast.relativeLuminance(ofCSS: " #FFFFFF "), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ReaderContrast.relativeLuminance(ofCSS: "rgb(255,255,255)"), 0.0)
        XCTAssertEqual(ReaderContrast.relativeLuminance(ofCSS: "#fff"), 0.0)
        XCTAssertEqual(ReaderContrast.relativeLuminance(ofCSS: ""), 0.0)
    }

    // MARK: Palette selection

    func testLightPageGetsYellowMarkerWithBlackText() {
        let colors = ReaderContrast.hitColors(background: "#ffffff", text: "#000000")

        XCTAssertEqual(colors.hitBackground, "#FFEE58")
        XCTAssertEqual(colors.hitText, "#000000")
        XCTAssertEqual(ReaderContrast.ratio(colors.hitText, colors.hitBackground), 17.62, accuracy: 0.01)
    }

    func testDarkPageGetsDeepAmberWithWhiteText() {
        let colors = ReaderContrast.hitColors(background: "#1c1c1e", text: "#e8e0d4")

        XCTAssertEqual(colors.hitBackground, "#7A5F00")
        XCTAssertEqual(colors.hitText, "#FFFFFF")
        XCTAssertEqual(ReaderContrast.ratio(colors.hitText, colors.hitBackground), 6.06, accuracy: 0.01)
    }

    func testActiveHitKeepsSystemSelectionColors() {
        let colors = ReaderContrast.hitColors(background: "#ffffff", text: "#000000")

        XCTAssertEqual(colors.activeBackground, "Highlight")
        XCTAssertEqual(colors.activeText, "HighlightText")
    }

    func testTextOverHitMeetsTheMinimumForEverySeededThemeInLightAndDark() {
        XCTAssertFalse(SettingsManager.seedThemes.isEmpty)
        for theme in SettingsManager.seedThemes {
            for (mode, set) in [("light", theme.light), ("dark", theme.dark)] {
                let colors = ReaderContrast.hitColors(background: set.background, text: set.text)
                XCTAssertGreaterThanOrEqual(
                    ReaderContrast.ratio(colors.hitText, colors.hitBackground),
                    ReaderContrast.minimumTextRatio,
                    "\(theme.name) \(mode)")
            }
        }
    }

    func testTextOverHitMeetsTheMinimumAcrossTheLuminanceRangeAndForUnparseableInput() {
        let pages = [
            "#000000", "#101010", "#2c2c2c", "#555555", "#777777", "#999999", "#cccccc", "#f4ecd8",
            "#ffffff", "not a color", "", "rgb(10,10,10)",
        ]
        for page in pages {
            let colors = ReaderContrast.hitColors(background: page, text: "#808080")
            XCTAssertGreaterThanOrEqual(
                ReaderContrast.ratio(colors.hitText, colors.hitBackground),
                ReaderContrast.minimumTextRatio,
                "page \(page)")
        }
    }

    // MARK: CSS wiring

    func testReaderVarsCSSEmitsTheFourHitVariables() {
        let hit = ReaderContrast.hitColors(background: "#ffffff", text: "#000000")
        let css = EPUBParser.readerVarsCSS(makeCosmetics(hit))

        XCTAssertTrue(css.contains("--reader-hit-bg: #FFEE58;"))
        XCTAssertTrue(css.contains("--reader-hit-text: #000000;"))
        XCTAssertTrue(css.contains("--reader-hit-active-bg: Highlight;"))
        XCTAssertTrue(css.contains("--reader-hit-active-text: HighlightText;"))
    }

    func testHitVariablesFollowAThemeChangeInTheVarsBlock() {
        let light = EPUBParser.readerVarsCSS(
            makeCosmetics(ReaderContrast.hitColors(background: "#ffffff", text: "#000000")))
        let dark = EPUBParser.readerVarsCSS(
            makeCosmetics(ReaderContrast.hitColors(background: "#1c1c1e", text: "#e8e0d4")))

        XCTAssertNotEqual(light, dark)
        XCTAssertTrue(dark.contains("--reader-hit-bg: #7A5F00;"))
    }

    func testReaderCSSHitRulesUseVariablesAndNoFixedYellow() {
        let css = EPUBParser.readerCSS

        XCTAssertFalse(css.contains("FFEE58"))
        XCTAssertTrue(css.contains("background: var(--reader-hit-bg);"))
        XCTAssertTrue(css.contains("color: var(--reader-hit-text);"))
        XCTAssertTrue(css.contains("background: var(--reader-hit-active-bg);"))
        XCTAssertTrue(css.contains("color: var(--reader-hit-active-text);"))
        XCTAssertTrue(css.contains("outline: 2px solid var(--reader-hit-text);"))
    }

    private func makeCosmetics(_ hit: ReaderContrast.HitColors) -> ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: 100,
            fontFamily: "serif",
            backgroundCSS: "#ffffff",
            textCSS: "#000000",
            linkCSS: "#0068da",
            hitBackground: hit.hitBackground,
            hitText: hit.hitText,
            hitActiveBackground: hit.activeBackground,
            hitActiveText: hit.activeText,
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
}
