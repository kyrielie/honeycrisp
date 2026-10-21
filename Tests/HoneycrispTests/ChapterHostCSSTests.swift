import Foundation
import XCTest
@testable import Honeycrisp

extension ReaderCosmeticSettings {
    /// Light theme with Georgia, 100% size, 1.6 line height, 700 px wide, 24 px side padding.
    static var chapterHostFixture: ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: 100,
            fontFamily: "Georgia, serif",
            backgroundCSS: "#ffffff",
            textCSS: "#000000",
            linkCSS: "#0068da",
            hitBackground: "#ffee58",
            hitText: "#000000",
            hitActiveBackground: "#ffa000",
            hitActiveText: "#000000",
            lineHeight: 1.6,
            maxWidth: 700,
            paddingH: 24,
            allowLinkClicks: true
        )
    }
}

final class ChapterHostCSSTests: XCTestCase {
    func testUserBlockAlwaysCarriesTheVariables() {
        let block = ChapterHostCSS.userBlock(.chapterHostFixture)
        XCTAssertTrue(block.contains(":root {"))
        XCTAssertTrue(block.contains("--reader-font-family: Georgia, serif;"))
        XCTAssertTrue(block.contains("--reader-bg: #ffffff;"))
        XCTAssertEqual(block, EPUBParser.readerVarsCSS(.chapterHostFixture), "defaults add no optional rules")
    }

    func testAlignmentRuleExistsOnlyWhenNotBookDefault() {
        var cosmetics = ReaderCosmeticSettings.chapterHostFixture
        XCTAssertFalse(ChapterHostCSS.userBlock(cosmetics).contains("p { text-align"))
        // The variable is defined (as `inherit`), but no rule may apply it: it would override the book's own `p`.
        cosmetics.textAlignment = .justify
        XCTAssertTrue(ChapterHostCSS.userBlock(cosmetics).contains("p { text-align: var(--reader-text-align); }"))
    }

    func testHyphenationRuleExistsOnlyWhenEnabledWithAValidLanguage() {
        var cosmetics = ReaderCosmeticSettings.chapterHostFixture
        cosmetics.hyphenate = true
        XCTAssertFalse(ChapterHostCSS.userBlock(cosmetics).contains("p { hyphens"), "no language, no hyphenation")
        cosmetics.language = "en"
        XCTAssertTrue(ChapterHostCSS.userBlock(cosmetics).contains("p { hyphens: var(--reader-hyphens)"))
        cosmetics.hyphenate = false
        XCTAssertFalse(ChapterHostCSS.userBlock(cosmetics).contains("p { hyphens"))
    }

    func testIndentRuleExistsOnlyWhenSet() {
        var cosmetics = ReaderCosmeticSettings.chapterHostFixture
        XCTAssertFalse(ChapterHostCSS.userBlock(cosmetics).contains("p { text-indent"))
        cosmetics.paragraphIndent = 1.5
        XCTAssertTrue(ChapterHostCSS.userBlock(cosmetics).contains("p { text-indent: var(--reader-paragraph-indent); }"))
    }

    func testStaticStylesheetNeverTouchesPropertiesTheBookOwns() {
        let css = ChapterHostCSS.stylesheet
        for property in [
            "text-align", "text-indent", "hyphens", "white-space", "display", "font-style", "font-variant",
            "text-decoration", "direction", "list-style",
        ] {
            XCTAssertFalse(css.contains(property), "\(property) belongs to the book or to a conditional rule")
        }
    }

    func testOwnedPropertiesAreImportantAndOptionalOnesAreNot() {
        let lines = ChapterHostCSS.stylesheet.components(separatedBy: "\n")
        let owned = [
            "var(--reader-font-family)", "var(--reader-text)", "var(--reader-line-height)", "var(--reader-link)",
            "var(--reader-bg)",
        ]
        for token in owned {
            let declaration = lines.first { $0.contains(token) }
            XCTAssertNotNil(declaration, token)
            XCTAssertTrue(declaration?.contains("!important") ?? false, "\(token) must win over the book")
        }
        for token in ["--reader-paragraph-spacing", "--reader-bold-weight"] {
            let declaration = lines.first { $0.contains(token) }
            XCTAssertNotNil(declaration, token)
            XCTAssertFalse(declaration?.contains("!important") ?? true, "\(token) must lose to book classes")
        }
    }

    func testResetRulesLiveInALowPriorityLayer() throws {
        let css = ChapterHostCSS.stylesheet
        XCTAssertTrue(css.hasPrefix("@layer app-reset {"))
        let layerEnd = try XCTUnwrap(css.range(of: "\n}\n"))
        XCTAssertFalse(css[layerEnd.upperBound...].contains("box-sizing"), "reset rules stay inside the layer")
    }
}
