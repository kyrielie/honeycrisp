import Foundation
import XCTest
@testable import Honeycrisp

final class ResolveTests: XCTestCase {
    private func theme(light: SkinColorTokens?, dark: SkinColorTokens?) -> ReaderSkin {
        ReaderSkin(
            id: "test.resolve", name: "Resolve", creator: nil, version: nil, css: "", template: "",
            light: light, dark: dark, usesDefaultColors: false, lowContrast: false,
            fontImports: [], familyGroup: nil, familyVariant: nil, license: nil)
    }

    private let lightTokens = SkinColorTokens(background: "#f4ecd8", ink: "#433422", link: "#8a5a2b")
    private let darkTokens = SkinColorTokens(background: "#2b2216", ink: "#d8c9a8", link: "#c99a55")

    func testNoThemeNoOverridesGivesBaseline() {
        let result = ReaderCosmeticSettings.resolve(theme: nil, overrides: .none, isDark: false, allowLinkClicks: true)
        XCTAssertEqual(result.backgroundCSS, ReaderBaseline.background)
        XCTAssertEqual(result.textCSS, ReaderBaseline.text)
        XCTAssertEqual(result.linkCSS, ReaderBaseline.link)
        XCTAssertEqual(result.fontFamily, FontPresets.defaultStack)
        XCTAssertEqual(result.fontSizePercent, 100)
        XCTAssertEqual(result.lineHeight, 1.6)
        XCTAssertEqual(result.maxWidth, 700)
        XCTAssertEqual(result.paddingH, 24)
        XCTAssertEqual(result.paddingV, 24)
        XCTAssertEqual(result.paragraphIndent, 0.3)
        XCTAssertEqual(result.paragraphSpacing, 0.5)
        XCTAssertFalse(result.justify)
        XCTAssertFalse(result.hyphenate)
        XCTAssertTrue(result.allowLinkClicks)
        XCTAssertEqual(result.overrides, .none)
    }

    func testThemeTokensAreUsedPerMode() {
        let paper = theme(light: lightTokens, dark: darkTokens)
        let light = ReaderCosmeticSettings.resolve(theme: paper, overrides: .none, isDark: false, allowLinkClicks: true)
        let dark = ReaderCosmeticSettings.resolve(theme: paper, overrides: .none, isDark: true, allowLinkClicks: true)
        XCTAssertEqual(light.backgroundCSS, "#f4ecd8")
        XCTAssertEqual(dark.backgroundCSS, "#2b2216")
        XCTAssertEqual(dark.textCSS, "#d8c9a8")
        XCTAssertEqual(dark.linkCSS, "#c99a55")
    }

    func testDarkFallsBackToLightTokensWhenThemeHasNoDark() {
        let single = theme(light: lightTokens, dark: nil)
        let dark = ReaderCosmeticSettings.resolve(theme: single, overrides: .none, isDark: true, allowLinkClicks: true)
        XCTAssertEqual(dark.backgroundCSS, "#f4ecd8")
    }

    func testOverrideBeatsThemeToken() {
        var overrides = ReaderOverrides()
        overrides.light.background = "#ABCDEF"
        let result = ReaderCosmeticSettings.resolve(
            theme: theme(light: lightTokens, dark: darkTokens), overrides: overrides, isDark: false, allowLinkClicks: true)
        XCTAssertEqual(result.backgroundCSS, "#abcdef")
        XCTAssertEqual(result.textCSS, "#433422")
    }

    func testPerModeOverrideOnlyAffectsItsMode() {
        var overrides = ReaderOverrides()
        overrides.dark.ink = "#ffffff"
        let paper = theme(light: lightTokens, dark: darkTokens)
        let light = ReaderCosmeticSettings.resolve(theme: paper, overrides: overrides, isDark: false, allowLinkClicks: true)
        let dark = ReaderCosmeticSettings.resolve(theme: paper, overrides: overrides, isDark: true, allowLinkClicks: true)
        XCTAssertEqual(light.textCSS, "#433422")
        XCTAssertEqual(dark.textCSS, "#ffffff")
    }

    func testInvalidOverrideIsIgnored() {
        var overrides = ReaderOverrides()
        overrides.light.background = "not a color"
        let result = ReaderCosmeticSettings.resolve(
            theme: theme(light: lightTokens, dark: darkTokens), overrides: overrides, isDark: false, allowLinkClicks: true)
        XCTAssertEqual(result.backgroundCSS, "#f4ecd8")
    }

    func testNumericOverridesAreAppliedAndClamped() {
        var overrides = ReaderOverrides()
        overrides.fontSizePercent = 140
        overrides.lineHeight = 9
        overrides.maxWidth = 900
        overrides.justify = true
        let result = ReaderCosmeticSettings.resolve(theme: nil, overrides: overrides, isDark: false, allowLinkClicks: false)
        XCTAssertEqual(result.fontSizePercent, 140)
        XCTAssertEqual(result.lineHeight, 2.4)
        XCTAssertEqual(result.maxWidth, 900)
        XCTAssertTrue(result.justify)
        XCTAssertFalse(result.allowLinkClicks)
    }

    func testRemoveParagraphIndentsZeroesIndentUnlessUserChoseOne() {
        let removed = ReaderCosmeticSettings.resolve(
            theme: nil, overrides: .none, isDark: false, allowLinkClicks: true, removeParagraphIndents: true)
        XCTAssertEqual(removed.paragraphIndent, 0)
        var explicit = ReaderOverrides()
        explicit.paragraphIndent = 1.5
        let kept = ReaderCosmeticSettings.resolve(
            theme: nil, overrides: explicit, isDark: false, allowLinkClicks: true, removeParagraphIndents: true)
        XCTAssertEqual(kept.paragraphIndent, 1.5)
    }

    func testResolvedOverridesAreSanitizedAndCarried() {
        var overrides = ReaderOverrides()
        overrides.bodyFont = "Georgia, serif"
        overrides.paddingH = 5000
        let result = ReaderCosmeticSettings.resolve(theme: nil, overrides: overrides, isDark: false, allowLinkClicks: true)
        XCTAssertEqual(result.fontFamily, "Georgia, serif")
        XCTAssertEqual(result.paddingH, 120)
        XCTAssertEqual(result.overrides.paddingH, 120)
    }
}
