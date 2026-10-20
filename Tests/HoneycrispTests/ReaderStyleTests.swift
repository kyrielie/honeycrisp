import Foundation
import XCTest
@testable import Honeycrisp

/// Code-font override. String-level only: whether WebKit actually renders the theme font needs a
/// manual check on a synthetic fixture.
final class ReaderStyleTests: XCTestCase {
    // MARK: Code font override

    func testReaderCSSCodeRuleUsesVariableNotFixedMonospace() {
        let css = EPUBParser.readerCSS
        XCTAssertTrue(css.contains("font-family: var(--reader-code-font-family) !important;"))
        XCTAssertFalse(css.contains("ui-monospace"))
    }

    func testVarsUseThemeFontForCodeWhenOverridden() {
        let vars = EPUBParser.readerVarsCSS(makeCosmetics(overrideMonospace: true))
        XCTAssertTrue(vars.contains("--reader-code-font-family: Charter, Georgia, serif;"))
    }

    func testVarsUseMonospaceStackWhenNotOverridden() {
        let vars = EPUBParser.readerVarsCSS(makeCosmetics(overrideMonospace: false))
        XCTAssertTrue(vars.contains("--reader-code-font-family: \(EPUBParser.monospaceStack);"))
        XCTAssertTrue(vars.contains("--reader-font-family: Charter, Georgia, serif;"))
    }

    func testCosmeticSettingsDefaultToOverridingMonospace() {
        XCTAssertTrue(makeCosmetics().overrideMonospace)
    }

    func testTextAlignmentAndHyphenationUseLowSpecificityCSS() {
        let vars = EPUBParser.readerVarsCSS(
            makeCosmetics(textAlignment: .center, hyphenate: true, language: "en-US")
        )
        XCTAssertTrue(vars.contains("--reader-text-align: center;"))
        XCTAssertTrue(vars.contains("--reader-hyphens: auto;"))
        XCTAssertTrue(EPUBParser.readerCSS.contains("p {"))
        XCTAssertTrue(EPUBParser.readerCSS.contains("text-align: var(--reader-text-align);"))
        XCTAssertTrue(EPUBParser.readerCSS.contains("-webkit-hyphens: var(--reader-hyphens);"))
    }

    func testHyphenationIsDisabledWhenLanguageIsMissingOrInvalid() {
        let missing = EPUBParser.readerVarsCSS(makeCosmetics(hyphenate: true))
        let invalid = EPUBParser.readerVarsCSS(makeCosmetics(hyphenate: true, language: "en\"><script"))
        XCTAssertTrue(missing.contains("--reader-hyphens: manual;"))
        XCTAssertTrue(invalid.contains("--reader-hyphens: manual;"))
    }

    func testReaderVarsCarryParagraphSpacingAndBoldWeight() {
        let vars = EPUBParser.readerVarsCSS(makeCosmetics(paragraphSpacing: 1.5, boldWeight: .medium))
        XCTAssertTrue(vars.contains("--reader-paragraph-spacing: 1.5em;"))
        XCTAssertTrue(vars.contains("--reader-bold-weight: 600;"))
        XCTAssertTrue(EPUBParser.readerCSS.contains("margin-block-end: var(--reader-paragraph-spacing) !important;"))
        XCTAssertTrue(EPUBParser.readerCSS.contains("b, strong { font-weight: var(--reader-bold-weight); }"))
    }

    func testFirstLineIndentIsOptionalAndSanitized() {
        let bookDefault = EPUBParser.readerVarsCSS(makeCosmetics())
        let custom = EPUBParser.readerVarsCSS(makeCosmetics(paragraphIndent: 2.5))
        XCTAssertFalse(bookDefault.contains("--reader-paragraph-indent:"))
        XCTAssertTrue(custom.contains("--reader-paragraph-indent: 2.5em;"))
        XCTAssertTrue(EPUBParser.readerCSS.contains("text-indent: var(--reader-paragraph-indent);"))
    }

    // MARK: Setting

    func testUseThemeFontForCodeSettingDefaultsPersistsAndResets() {
        let suite = "HoneycrispTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SettingsManager(defaults: defaults)

        XCTAssertTrue(manager.useThemeFontForCode)
        XCTAssertFalse(manager.isReaderCustomized)

        manager.useThemeFontForCode = false
        XCTAssertFalse(SettingsManager(defaults: defaults).useThemeFontForCode)
        XCTAssertTrue(manager.isReaderCustomized)

        manager.resetReaderToDefaults()
        XCTAssertTrue(manager.useThemeFontForCode)
        XCTAssertFalse(manager.isReaderCustomized)
    }

    // MARK: Helpers

    private func makeCosmetics(
        overrideMonospace: Bool = true,
        textAlignment: ThemeTextAlignment = .book,
        hyphenate: Bool = false,
        language: String? = nil,
        paragraphSpacing: Double = 1.0,
        paragraphIndent: Double? = nil,
        boldWeight: ThemeBoldWeight = .book
    ) -> ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: 100,
            fontFamily: "Charter, Georgia, serif",
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
            allowLinkClicks: true,
            overrideMonospace: overrideMonospace,
            textAlignment: textAlignment,
            hyphenate: hyphenate,
            language: language,
            paragraphSpacing: paragraphSpacing,
            paragraphIndent: paragraphIndent,
            boldWeight: boldWeight
        )
    }
}
