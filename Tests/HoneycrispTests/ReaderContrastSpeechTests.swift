//
//  ReaderContrastSpeechTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
@testable import Honeycrisp
import XCTest

final class ReaderContrastSpeechTests: XCTestCase {
    func testHexColorWithAlphaSanitizer() {
        XCTAssertEqual(ReaderCSSSanitizer.hexColorWithAlpha("#0068DA2E", fallback: "#ffffff00"), "#0068da2e")
        XCTAssertEqual(ReaderCSSSanitizer.hexColorWithAlpha("12345678", fallback: "#ffffff00"), "#12345678")
        XCTAssertEqual(ReaderCSSSanitizer.hexColorWithAlpha("#12345", fallback: "#ffffff00"), "#ffffff00")
        XCTAssertEqual(ReaderCSSSanitizer.hexColorWithAlpha("invalid", fallback: "#ffffff00"), "#ffffff00")
    }

    func testBlendKnownValues() {
        // Blending white over black at 50% (128/255)
        let blended = ReaderContrast.blend(foreground: "#FFFFFF", alpha: 128, over: "#000000")
        XCTAssertEqual(blended, "#808080")
    }

    func testSpeechColorsAreEightDigitHex() {
        let colors = ReaderContrast.speechColors(background: "#FFFFFF", text: "#000000", link: "#0068DA")
        XCTAssertTrue(colors.sentence.hasPrefix("#"))
        XCTAssertEqual(colors.sentence.count, 9) // #RRGGBBAA
        XCTAssertTrue(colors.word.hasPrefix("#"))
        XCTAssertEqual(colors.word.count, 9)
    }

    func testSpeechTextKeepsContrastOnLightPage() {
        let colors = ReaderContrast.speechColors(background: "#FFFFFF", text: "#000000", link: "#0068DA")
        let sentenceAlphaHex = String(colors.sentence.suffix(2))
        let sentenceAlpha = UInt8(sentenceAlphaHex, radix: 16)!
        let sentenceBlended = ReaderContrast.blend(foreground: "#0068DA", alpha: sentenceAlpha, over: "#FFFFFF")

        XCTAssertGreaterThanOrEqual(ReaderContrast.ratio(sentenceBlended, "#000000"), ReaderContrast.minimumTextRatio)
    }

    func testSpeechTextKeepsContrastOnDarkPage() {
        let colors = ReaderContrast.speechColors(background: "#1A1A1A", text: "#E6E6E6", link: "#6CB6FF")
        let sentenceAlphaHex = String(colors.sentence.suffix(2))
        let sentenceAlpha = UInt8(sentenceAlphaHex, radix: 16)!
        let sentenceBlended = ReaderContrast.blend(foreground: "#6CB6FF", alpha: sentenceAlpha, over: "#1A1A1A")

        XCTAssertGreaterThanOrEqual(ReaderContrast.ratio(sentenceBlended, "#E6E6E6"), ReaderContrast.minimumTextRatio)
    }
}
