import XCTest

@testable import Honeycrisp

final class SettingsValueFormatTests: XCTestCase {
    func testEmKeepsQuarterSteps() {
        XCTAssertEqual(SettingsValueFormat.em(1.0), "1.0 em")
        XCTAssertEqual(SettingsValueFormat.em(0.25), "0.25 em")
        XCTAssertEqual(SettingsValueFormat.em(1.25), "1.25 em")
        XCTAssertEqual(SettingsValueFormat.em(1.75), "1.75 em")
        XCTAssertEqual(SettingsValueFormat.em(2.75), "2.75 em")
        XCTAssertEqual(SettingsValueFormat.em(0.5), "0.5 em")
        XCTAssertEqual(SettingsValueFormat.em(0), "0.0 em")
        XCTAssertEqual(SettingsValueFormat.em(3), "3.0 em")
    }

    func testEmHandlesNonFinite() {
        XCTAssertEqual(SettingsValueFormat.em(.nan), "0.0 em")
        XCTAssertEqual(SettingsValueFormat.em(.infinity), "0.0 em")
    }

    func testLineHeightLabelKeepsTwoDecimals() {
        XCTAssertEqual(SettingsValueFormat.lineHeight(1.6), "1.6")
        XCTAssertEqual(SettingsValueFormat.lineHeight(1.65), "1.65")
        XCTAssertEqual(SettingsValueFormat.lineHeight(.nan), "0.0")
    }

    func testPxLabel() {
        XCTAssertEqual(SettingsValueFormat.px(700), "700px")
        XCTAssertEqual(SettingsValueFormat.px(16.4), "16px")
        XCTAssertEqual(SettingsValueFormat.px(.nan), "0px")
    }

    func testParseNumberIgnoresUnitsAndAcceptsCommaDecimal() {
        XCTAssertEqual(SettingsValueFormat.parseNumber("700px"), 700)
        XCTAssertEqual(SettingsValueFormat.parseNumber(" 1.25 em "), 1.25)
        XCTAssertEqual(SettingsValueFormat.parseNumber("1,5"), 1.5)
        XCTAssertEqual(SettingsValueFormat.parseNumber("-4"), -4)
    }

    func testParseNumberRejectsTextAndNonFinite() {
        XCTAssertNil(SettingsValueFormat.parseNumber(""))
        XCTAssertNil(SettingsValueFormat.parseNumber("Book"))
        XCTAssertNil(SettingsValueFormat.parseNumber("nan"))
        XCTAssertNil(SettingsValueFormat.parseNumber("inf"))
    }

    func testLineHeightRangeMatchesSanitizer() {
        XCTAssertEqual(ReaderCSSSanitizer.lineHeightRange, 1.2...2.4)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(1.0), 1.2)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(3.0), 2.4)
        XCTAssertEqual(ReaderCSSSanitizer.lineHeight(1.8), 1.8)
    }
}

final class ValueSliderControlMathTests: XCTestCase {
    func testClampBoundsAndNonFinite() {
        XCTAssertEqual(ValueSliderControl.clamp(5, to: 1...3), 3)
        XCTAssertEqual(ValueSliderControl.clamp(-5, to: 1...3), 1)
        XCTAssertEqual(ValueSliderControl.clamp(.nan, to: 1...3), 1)
    }

    func testSnapCountsStepsFromLowerBound() {
        // Line height 1.2...2.4 in 0.1 steps: 1.26 snaps to 1.3, not to a multiple of 0.1 from zero.
        XCTAssertEqual(ValueSliderControl.snap(1.26, range: 1.2...2.4, step: 0.1, fractionDigits: 2), 1.3)
        XCTAssertEqual(ValueSliderControl.snap(1.234, range: 1.2...2.4, step: 0.1, fractionDigits: 2), 1.2)
        // Max width 320...1400 in 20 px steps.
        XCTAssertEqual(ValueSliderControl.snap(333, range: 320...1400, step: 20, fractionDigits: 0), 340)
        XCTAssertEqual(ValueSliderControl.snap(329, range: 320...1400, step: 20, fractionDigits: 0), 320)
    }

    func testSnapClampsAndHandlesBadInput() {
        XCTAssertEqual(ValueSliderControl.snap(9_999, range: 0...120, step: 4, fractionDigits: 0), 120)
        XCTAssertEqual(ValueSliderControl.snap(-50, range: 0...120, step: 4, fractionDigits: 0), 0)
        XCTAssertEqual(ValueSliderControl.snap(.nan, range: 0...120, step: 4, fractionDigits: 0), 0)
        XCTAssertEqual(ValueSliderControl.snap(10, range: 0...120, step: 0, fractionDigits: 0), 0)
    }

    func testSnapQuarterEmSteps() {
        XCTAssertEqual(ValueSliderControl.snap(1.1, range: 0...3, step: 0.25, fractionDigits: 2), 1.0)
        XCTAssertEqual(ValueSliderControl.snap(1.2, range: 0...3, step: 0.25, fractionDigits: 2), 1.25)
        XCTAssertEqual(ValueSliderControl.snap(0.9, range: 0...3, step: 0.25, fractionDigits: 2), 1.0)
    }

    func testRoundedToDigits() {
        XCTAssertEqual(ValueSliderControl.roundedToDigits(1.2345, fractionDigits: 2), 1.23)
        XCTAssertEqual(ValueSliderControl.roundedToDigits(700.4, fractionDigits: 0), 700)
    }
}
