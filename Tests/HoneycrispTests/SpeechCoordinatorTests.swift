//
//  SpeechCoordinatorTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-23.
//

import AVFoundation
@testable import Honeycrisp
import XCTest

@MainActor
private final class MockSpeechCoordinatorDelegate: SpeechCoordinatorDelegate {
    var stateChanges: [SpeechCoordinator.PlaybackState] = []
    var nextChapterToReturn: (chapterIndex: Int, text: String)?
    var prevChapterToReturn: (chapterIndex: Int, text: String)?

    func speechCoordinator(_ coordinator: SpeechCoordinator, didChangeState state: SpeechCoordinator.PlaybackState) {
        stateChanges.append(state)
    }

    func speechCoordinatorRequestsNextChapter(
        _ coordinator: SpeechCoordinator,
        afterChapter chapterIndex: Int
    ) -> (chapterIndex: Int, text: String)? {
        nextChapterToReturn
    }

    func speechCoordinatorRequestsPreviousChapter(
        _ coordinator: SpeechCoordinator,
        beforeChapter chapterIndex: Int
    ) -> (chapterIndex: Int, text: String)? {
        prevChapterToReturn
    }
}

@MainActor
private final class MockTTSEngine: TTSEngine {
    let identifier = "test.mock"
    let displayName = "Mock Engine"
    weak var delegate: TTSEngineDelegate?

    var availableVoices: [TTSVoice] = [
        TTSVoice(id: "mock.voice.1", name: "Mock Voice", language: "en-US", quality: .premium)
    ]
    var preferredVoiceIdentifier: String? { "mock.voice.1" }

    var spokenChunks: [String] = []
    var stopCount = 0
    var pauseCount = 0

    func speak(chunk: String, voiceIdentifier: String?, rate: Float) {
        spokenChunks.append(chunk)
        delegate?.ttsEngineDidStartUtterance(self)
    }

    func pause() { pauseCount += 1 }
    func resume() {}
    func stop() { stopCount += 1 }
}

@MainActor
final class SpeechCoordinatorTests: XCTestCase {
    func testAvailableVoicesFilterOutLegacyAndEloquence() {
        let voices = SpeechCoordinator.defaultVoices
        for voice in voices {
            XCTAssertFalse(voice.id.contains(".eloquence."))
            XCTAssertFalse(voice.id.starts(with: "com.apple.speech.synthesis.voice."))
        }
    }

    func testVoiceQualitySortingAndDisplayName() {
        let voices = SpeechCoordinator.defaultVoices
        guard !voices.isEmpty else { return }

        for i in 0..<(voices.count - 1) {
            XCTAssertGreaterThanOrEqual(
                voices[i].quality,
                voices[i + 1].quality,
                "Voices must be ordered with higher quality first"
            )
        }

        let first = voices[0]
        let displayName = first.displayName
        XCTAssertTrue(displayName.contains(first.name))
        XCTAssertTrue(displayName.contains(first.language))

        let engine = AVFoundationTTSEngine()
        XCTAssertNotNil(engine.preferredVoiceIdentifier)
    }

    func testPluggableEngineHandoffAndProgression() {
        let mock = MockTTSEngine()
        let coordinator = SpeechCoordinator(engine: mock)
        let text = "Sentence one. Sentence two."
        coordinator.start(chapterIndex: 0, text: text)

        XCTAssertEqual(mock.spokenChunks.count, 1)
        XCTAssertEqual(mock.spokenChunks.first, "Sentence one.")

        mock.delegate?.ttsEngineDidFinishUtterance(mock)
        XCTAssertEqual(mock.spokenChunks.count, 2)
        XCTAssertEqual(mock.spokenChunks[1], "Sentence two.")

        let mock2 = MockTTSEngine()
        coordinator.engine = mock2
        XCTAssertGreaterThanOrEqual(mock.stopCount, 1)
        XCTAssertEqual(coordinator.availableVoices.first?.id, "mock.voice.1")
    }

    func testInitialStateIsIdle() {
        let coordinator = SpeechCoordinator()
        XCTAssertEqual(coordinator.playbackState, .idle)
        XCTAssertFalse(coordinator.playbackState.isPlaying)
        XCTAssertFalse(coordinator.playbackState.isPaused)
    }

    func testStartAndStopPlayback() {
        let coordinator = SpeechCoordinator()
        let delegate = MockSpeechCoordinatorDelegate()
        coordinator.delegate = delegate

        let text = "First sentence here. Second sentence follows. Third and final sentence."
        coordinator.start(chapterIndex: 0, text: text)

        XCTAssertTrue(coordinator.playbackState.isPlaying)
        if case let .playing(ch, idx, total) = coordinator.playbackState {
            XCTAssertEqual(ch, 0)
            XCTAssertEqual(idx, 0)
            XCTAssertEqual(total, 3)
        } else {
            XCTFail("Expected playing state")
        }

        coordinator.pause()
        XCTAssertTrue(coordinator.playbackState.isPaused)
        if case let .paused(ch, idx, total) = coordinator.playbackState {
            XCTAssertEqual(ch, 0)
            XCTAssertEqual(idx, 0)
            XCTAssertEqual(total, 3)
        } else {
            XCTFail("Expected paused state")
        }

        coordinator.resume()
        XCTAssertTrue(coordinator.playbackState.isPlaying)

        coordinator.stop()
        XCTAssertEqual(coordinator.playbackState, .idle)
    }

    func testSkipNextAndPrevious() {
        let coordinator = SpeechCoordinator()
        let text = "Sentence one. Sentence two. Sentence three."
        coordinator.start(chapterIndex: 0, text: text)

        coordinator.skipNext()
        if case let .playing(_, idx, _) = coordinator.playbackState {
            XCTAssertEqual(idx, 1)
        } else {
            XCTFail("Expected playing state at index 1")
        }

        coordinator.skipNext()
        if case let .playing(_, idx, _) = coordinator.playbackState {
            XCTAssertEqual(idx, 2)
        } else {
            XCTFail("Expected playing state at index 2")
        }

        coordinator.skipPrevious()
        if case let .playing(_, idx, _) = coordinator.playbackState {
            XCTAssertEqual(idx, 1)
        } else {
            XCTFail("Expected playing state at index 1")
        }

        coordinator.stop()
    }

    func testSkipNextAdvancesToNextChapterViaDelegate() {
        let coordinator = SpeechCoordinator()
        let delegate = MockSpeechCoordinatorDelegate()
        delegate.nextChapterToReturn = (1, "Chapter two sentence one. Chapter two sentence two.")
        coordinator.delegate = delegate

        coordinator.start(chapterIndex: 0, text: "Only one sentence.")
        XCTAssertTrue(coordinator.playbackState.isPlaying)

        coordinator.skipNext()
        if case let .playing(ch, idx, total) = coordinator.playbackState {
            XCTAssertEqual(ch, 1)
            XCTAssertEqual(idx, 0)
            XCTAssertEqual(total, 2)
        } else {
            XCTFail("Expected chapter 1 playing")
        }

        coordinator.stop()
    }

    func testRateAdjustment() {
        let coordinator = SpeechCoordinator()
        let initialRate = coordinator.rate
        coordinator.adjustRate(by: 0.1)
        XCTAssertEqual(coordinator.rate, initialRate + 0.1, accuracy: 0.001)

        coordinator.adjustRate(by: -5.0)
        XCTAssertEqual(coordinator.rate, AVSpeechUtteranceMinimumSpeechRate)

        coordinator.adjustRate(by: 10.0)
        XCTAssertEqual(coordinator.rate, AVSpeechUtteranceMaximumSpeechRate)
    }
}
