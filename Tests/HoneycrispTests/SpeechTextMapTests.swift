//
//  SpeechTextMapTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
@testable import Honeycrisp
import XCTest

final class SpeechTextMapTests: XCTestCase {
    func testBlockBreaksSplitHeadingFromParagraph() throws {
        let html = "<h1>Title</h1><p>One. Two.</p>"
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)
        let map = SpeechTextMap.make(from: chapterText)
        let sentences = map.sentences()

        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences[0].text, "Title")
        XCTAssertEqual(sentences[1].text, "One.")
        XCTAssertEqual(sentences[2].text, "Two.")
    }

    func testMinifiedBlocksStillBreak() throws {
        let html = "<p>A</p><p>B</p>"
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)
        let map = SpeechTextMap.make(from: chapterText)
        XCTAssertEqual(map.text, "A\nB")
        let sentences = map.sentences()
        XCTAssertEqual(sentences.map(\.text), ["A", "B"])
    }

    func testHiddenAriaScriptStyleAreSkipped() throws {
        let html = """
        <p>Visible start.</p>
        <div hidden><p>Hidden text.</p></div>
        <p aria-hidden="true">Aria hidden.</p>
        <script>var x = 1;</script>
        <style>body { color: red; }</style>
        <p>Visible end.</p>
        """
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)
        let map = SpeechTextMap.make(from: chapterText)
        let full = map.text
        XCTAssertTrue(full.contains("Visible start."))
        XCTAssertTrue(full.contains("Visible end."))
        XCTAssertFalse(full.contains("Hidden text"))
        XCTAssertFalse(full.contains("Aria hidden"))
        XCTAssertFalse(full.contains("var x = 1"))
        XCTAssertFalse(full.contains("color: red"))
    }

    func testWhitespaceCollapsesAndMapsToFirstRealChar() throws {
        let html = "<p>a    \n  b</p>"
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)
        let map = SpeechTextMap.make(from: chapterText)
        XCTAssertEqual(map.text, "a b")
        XCTAssertEqual(map.chapterOffsets.count, 3)
        // 'a' is at index 0, ' ' maps to offset of 'b', 'b' is at index 2
        let nsChapter = chapterText.string as NSString
        let bOffset = (chapterText.string as NSString).range(of: "b").location
        XCTAssertEqual(map.chapterOffsets[1], bOffset)
        XCTAssertEqual(map.chapterOffsets[2], bOffset)
    }

    func testSentenceChapterRangesCoverTheirText() throws {
        let html = "<p>Hello world. Second sentence here.</p>"
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)
        let map = SpeechTextMap.make(from: chapterText)
        let sentences = map.sentences()
        XCTAssertEqual(sentences.count, 2)

        let ns = chapterText.string as NSString
        for sentence in sentences {
            let length = sentence.chapterEnd - sentence.chapterStart
            let sub = ns.substring(with: NSRange(location: sentence.chapterStart, length: length))
            XCTAssertEqual(sub, sentence.text)
        }
    }

    func testSpokenIndexForChapterOffsetBinarySearch() throws {
        let html = "<p>One. Two. Three.</p>"
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)
        let map = SpeechTextMap.make(from: chapterText)

        let zeroIndex = map.spokenIndex(forChapterOffset: 0)
        XCTAssertEqual(zeroIndex, 0)

        let pastEnd = map.spokenIndex(forChapterOffset: 9999)
        XCTAssertEqual(pastEnd, map.chapterOffsets.count - 1)
    }

    func testSentenceIndexContainingOrAfter() throws {
        let html = "<p>First sentence. Second sentence. Third sentence.</p>"
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)
        let map = SpeechTextMap.make(from: chapterText)
        let sentences = map.sentences()

        // Offset 0 is inside sentence 0
        XCTAssertEqual(map.sentenceIndex(containingOrAfter: 0), 0)

        // Offset at start of sentence 1
        let s1Start = sentences[1].chapterStart
        XCTAssertEqual(map.sentenceIndex(containingOrAfter: s1Start), 1)

        // Offset past end
        XCTAssertNil(map.sentenceIndex(containingOrAfter: 9999))
    }

    func testAbbreviationsDoNotSplit() {
        let text = "Mr. Smith went to Washington. He arrived safely."
        let ranges = ChapterSearch.speechChunkRanges(in: text)
        XCTAssertEqual(ranges.count, 2)

        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: ranges[0]), "Mr. Smith went to Washington.")
        XCTAssertEqual(ns.substring(with: ranges[1]), "He arrived safely.")
    }
}
