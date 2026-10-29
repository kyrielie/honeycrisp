//
//  SpeechToolbarStateTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
@testable import Honeycrisp
import XCTest

final class SpeechToolbarStateTests: XCTestCase {
    func testUnavailableWhenNoBook() {
        let state = SpeechToolbarState(playback: .idle, hasBook: false)
        XCTAssertEqual(state, .unavailable)
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.symbolName, "speaker.wave.2")
    }

    func testIdleWithBook() {
        let state = SpeechToolbarState(playback: .idle, hasBook: true)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.symbolName, "speaker.wave.2")
        XCTAssertTrue(state.tooltip.contains("Speak"))
    }

    func testActivePlaying() {
        let state = SpeechToolbarState(playback: .playing(chapterIndex: 0, chunkIndex: 0, totalChunks: 1), hasBook: true)
        XCTAssertEqual(state, .active(paused: false))
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.symbolName, "stop.fill")
        XCTAssertTrue(state.tooltip.contains("Stop speaking"))
        XCTAssertTrue(state.tooltip.contains("Option-click to pause"))
    }

    func testActivePaused() {
        let state = SpeechToolbarState(playback: .paused(chapterIndex: 0, chunkIndex: 0, totalChunks: 1), hasBook: true)
        XCTAssertEqual(state, .active(paused: true))
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.symbolName, "stop.fill")
        XCTAssertTrue(state.tooltip.contains("Option-click to resume"))
    }
}
