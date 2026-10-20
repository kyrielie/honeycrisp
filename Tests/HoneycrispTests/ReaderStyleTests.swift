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

    private func makeCosmetics(overrideMonospace: Bool = true) -> ReaderCosmeticSettings {
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
            overrideMonospace: overrideMonospace
        )
    }
}
