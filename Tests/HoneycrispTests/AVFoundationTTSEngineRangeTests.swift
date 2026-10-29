//
//  AVFoundationTTSEngineRangeTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
@testable import Honeycrisp
import XCTest

final class AVFoundationTTSEngineRangeTests: XCTestCase {
    func testRangeNearEndOfEmojiTextIsAccepted() {
        // "Hi \u{1F600} there" has 10 Characters but 11 UTF-16 code units (emoji is 2 units).
        // "there" is at location 6, length 5.
        let text = "Hi \u{1F600} there"
        let nsRange = NSRange(location: 6, length: 5)
        let range = AVFoundationTTSEngine.stringRange(for: nsRange, in: text)
        XCTAssertNotNil(range)
        if let range {
            XCTAssertEqual(String(text[range]), "there")
        }
    }

    func testCombiningSequenceRange() {
        let text = "e\u{0301}x"
        let nsRange = NSRange(location: 0, length: 2)
        let range = AVFoundationTTSEngine.stringRange(for: nsRange, in: text)
        XCTAssertNotNil(range)
        if let range {
            XCTAssertEqual(String(text[range]), "e\u{0301}")
        }
    }

    func testOutOfBoundsRangeIsNil() {
        let text = "abc"
        let nsRange = NSRange(location: 3, length: 10)
        let range = AVFoundationTTSEngine.stringRange(for: nsRange, in: text)
        XCTAssertNil(range)
    }

    func testNotFoundIsNil() {
        let text = "abc"
        let nsRange = NSRange(location: NSNotFound, length: 0)
        let range = AVFoundationTTSEngine.stringRange(for: nsRange, in: text)
        XCTAssertNil(range)
    }
}
