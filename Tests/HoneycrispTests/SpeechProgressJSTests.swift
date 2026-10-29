//
//  SpeechProgressJSTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
@testable import Honeycrisp
import XCTest

final class SpeechProgressJSTests: XCTestCase {
    func testHighlightJSSentenceOnly() {
        let progress = SpeechProgress(
            chapterIndex: 2,
            sentenceChapterRange: 10..<45,
            wordChapterRange: nil
        )
        let js = progress.highlightJS(includeWord: true, follow: false)
        XCTAssertEqual(js, "window.honeycrispSpeechHighlight(2, 10, 45, -1, -1, 0);")
    }

    func testHighlightJSSentenceWithWordAndFollow() {
        let progress = SpeechProgress(
            chapterIndex: 0,
            sentenceChapterRange: 0..<50,
            wordChapterRange: 12..<18
        )
        let js = progress.highlightJS(includeWord: true, follow: true)
        XCTAssertEqual(js, "window.honeycrispSpeechHighlight(0, 0, 50, 12, 18, 1);")
    }

    func testHighlightJSDisablingWordPassesNegativeOnes() {
        let progress = SpeechProgress(
            chapterIndex: 1,
            sentenceChapterRange: 5..<20,
            wordChapterRange: 7..<12
        )
        let js = progress.highlightJS(includeWord: false, follow: false)
        XCTAssertEqual(js, "window.honeycrispSpeechHighlight(1, 5, 20, -1, -1, 0);")
    }

    func testHighlightJSContainsOnlySafeCharacters() {
        let progress = SpeechProgress(
            chapterIndex: 3,
            sentenceChapterRange: 100..<200,
            wordChapterRange: 110..<120
        )
        let js = progress.highlightJS(includeWord: true, follow: true)
        // Should only contain function name and numbers, commas, spaces, parens, minus, semicolon
        let allowed = CharacterSet(charactersIn: "window.honeycrispSpeechHighlight0123456789, -();")
        XCTAssertTrue(js.unicodeScalars.allSatisfy { allowed.contains($0) })
    }
}
