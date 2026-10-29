//
//  SpeechStartResolverTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
@testable import Honeycrisp
import XCTest

final class SpeechStartResolverTests: XCTestCase {
    private func makeSentences() -> [SpeechSentence] {
        [
            SpeechSentence(spoken: NSRange(location: 0, length: 13), text: "Sentence one.", chapterStart: 0, chapterEnd: 13),
            SpeechSentence(spoken: NSRange(location: 14, length: 13), text: "Sentence two.", chapterStart: 14, chapterEnd: 27),
            SpeechSentence(spoken: NSRange(location: 28, length: 15), text: "Sentence three.", chapterStart: 28, chapterEnd: 43),
        ]
    }

    func testSelectionModeResolvesContainingSentence() {
        let sentences = makeSentences()
        // Offset 18 is inside Sentence two (14..<27)
        let idx = SpeechStartResolver.sentenceIndex(
            in: sentences,
            caretOffset: 18,
            source: .selection
        )
        XCTAssertEqual(idx, 1)
    }

    func testViewportModeResolvesNextStartingSentenceWhenOnScreen() {
        let sentences = makeSentences()
        // Caret at offset 5 (inside sentence 0)
        let idx = SpeechStartResolver.sentenceIndex(
            in: sentences,
            caretOffset: 5,
            source: .viewport,
            nextStartIsOnScreen: true
        )
        XCTAssertEqual(idx, 0)

        // Caret at offset 13 (in gap between sentence 0 and 1)
        let gapIdx = SpeechStartResolver.sentenceIndex(
            in: sentences,
            caretOffset: 13,
            source: .viewport,
            nextStartIsOnScreen: true
        )
        XCTAssertEqual(gapIdx, 1)
    }

    func testStartModeAlwaysStartsAtZero() {
        let sentences = makeSentences()
        let idx = SpeechStartResolver.sentenceIndex(
            in: sentences,
            caretOffset: 99,
            source: .start
        )
        XCTAssertEqual(idx, 0)
    }

    func testPastEndClampsToLastSentence() {
        let sentences = makeSentences()
        let idx = SpeechStartResolver.sentenceIndex(
            in: sentences,
            caretOffset: 999,
            source: .selection
        )
        XCTAssertEqual(idx, 2)
    }

    func testEmptySentencesReturnsNil() {
        let idx = SpeechStartResolver.sentenceIndex(
            in: [],
            caretOffset: 0,
            source: .viewport
        )
        XCTAssertNil(idx)
    }
}
