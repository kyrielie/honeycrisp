//
//  SpeechCoordinator.swift
//  Honeycrisp
//
//  Created on 2026-10-23.
//

import AVFoundation
import Foundation

@MainActor
protocol SpeechCoordinatorDelegate: AnyObject {
    func speechCoordinator(_ coordinator: SpeechCoordinator, didChangeState state: SpeechCoordinator.PlaybackState)
    func speechCoordinator(
        _ coordinator: SpeechCoordinator,
        willSpeakWordRange range: Range<String.Index>,
        inChunk chunk: String,
        chapterIndex: Int
    )
    func speechCoordinatorRequestsNextChapter(
        _ coordinator: SpeechCoordinator,
        afterChapter chapterIndex: Int
    ) -> (chapterIndex: Int, text: String)?
    func speechCoordinatorRequestsPreviousChapter(
        _ coordinator: SpeechCoordinator,
        beforeChapter chapterIndex: Int
    ) -> (chapterIndex: Int, text: String)?
}

extension SpeechCoordinatorDelegate {
    func speechCoordinator(
        _ coordinator: SpeechCoordinator,
        willSpeakWordRange range: Range<String.Index>,
        inChunk chunk: String,
        chapterIndex: Int
    ) {}
    func speechCoordinatorRequestsPreviousChapter(
        _ coordinator: SpeechCoordinator,
        beforeChapter chapterIndex: Int
    ) -> (chapterIndex: Int, text: String)? { nil }
}

/// Orchestrates text-to-speech reading with sentence chunking, pluggable TTSEngine backend,
/// automatic spine item auto-advance, and skip navigation.
@MainActor
final class SpeechCoordinator: NSObject {
    public enum PlaybackState: Equatable, Sendable {
        case idle
        case playing(chapterIndex: Int, chunkIndex: Int, totalChunks: Int)
        case paused(chapterIndex: Int, chunkIndex: Int, totalChunks: Int)

        public var isPlaying: Bool { if case .playing = self { return true } else { return false } }
        public var isPaused: Bool { if case .paused = self { return true } else { return false } }
    }

    weak var delegate: SpeechCoordinatorDelegate?

    public private(set) var playbackState: PlaybackState = .idle {
        didSet {
            if oldValue != playbackState { delegate?.speechCoordinator(self, didChangeState: playbackState) }
        }
    }

    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var voiceIdentifier: String?

    public var engine: TTSEngine {
        didSet {
            let wasPlaying = playbackState.isPlaying
            oldValue.stop()
            engine.delegate = self
            if wasPlaying { playCurrentChunk() }
        }
    }

    private var currentChapterIndex: Int = 0
    private var currentChunks: [String] = []
    private var currentChunkIndex: Int = 0

    init(engine: TTSEngine? = nil) {
        let activeEngine = engine ?? AVFoundationTTSEngine()
        self.engine = activeEngine
        super.init()
        self.engine.delegate = self
    }

    public var availableVoices: [TTSVoice] {
        engine.availableVoices
    }

    public static var defaultVoices: [TTSVoice] {
        AVFoundationTTSEngine().availableVoices
    }

    public var preferredVoiceIdentifier: String? {
        engine.preferredVoiceIdentifier
    }

    public static func displayName(for voice: TTSVoice) -> String {
        voice.displayName
    }

    func start(chapterIndex: Int, text: String) {
        let chunks = ChapterSearch.speechChunks(from: text)
        guard !chunks.isEmpty else { stop(); return }
        currentChapterIndex = chapterIndex
        currentChunks = chunks
        currentChunkIndex = 0
        playCurrentChunk()
    }

    func pause() {
        guard case let .playing(ch, idx, total) = playbackState else { return }
        playbackState = .paused(chapterIndex: ch, chunkIndex: idx, totalChunks: total)
        engine.pause()
    }

    func resume() {
        guard case let .paused(ch, idx, _) = playbackState else { return }
        currentChapterIndex = ch
        currentChunkIndex = idx
        playCurrentChunk()
    }

    func togglePlayPause(fallbackStart: () -> Void) {
        switch playbackState {
        case .playing: pause()
        case .paused: resume()
        case .idle: fallbackStart()
        }
    }

    func stop() {
        playbackState = .idle
        currentChunks = []
        currentChunkIndex = 0
        engine.stop()
    }

    func skipNext() {
        guard !currentChunks.isEmpty else { return }
        let wasPlaying = playbackState.isPlaying
        if currentChunkIndex + 1 < currentChunks.count {
            currentChunkIndex += 1
            updateChunkPosition(wasPlaying: wasPlaying)
        } else {
            advanceToNextChapter(autoPlay: wasPlaying)
        }
    }

    func skipPrevious() {
        guard !currentChunks.isEmpty else { return }
        let wasPlaying = playbackState.isPlaying
        if currentChunkIndex > 0 {
            currentChunkIndex -= 1
            updateChunkPosition(wasPlaying: wasPlaying)
        } else if let prev = delegate?.speechCoordinatorRequestsPreviousChapter(
            self,
            beforeChapter: currentChapterIndex
        ) {
            let chunks = ChapterSearch.speechChunks(from: prev.text)
            guard !chunks.isEmpty else { return }
            currentChapterIndex = prev.chapterIndex
            currentChunks = chunks
            currentChunkIndex = max(0, chunks.count - 1)
            updateChunkPosition(wasPlaying: wasPlaying)
        }
    }

    func adjustRate(by delta: Float) {
        rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate + delta))
    }

    func setVoice(identifier: String?) {
        voiceIdentifier = identifier
        if playbackState.isPlaying { playCurrentChunk() }
    }

    private func updateChunkPosition(wasPlaying: Bool) {
        if wasPlaying {
            playCurrentChunk()
        } else {
            playbackState = .paused(
                chapterIndex: currentChapterIndex,
                chunkIndex: currentChunkIndex,
                totalChunks: currentChunks.count
            )
        }
    }

    private func playCurrentChunk() {
        guard currentChunks.indices.contains(currentChunkIndex) else {
            advanceToNextChapter(autoPlay: true)
            return
        }
        let chunk = currentChunks[currentChunkIndex]
        playbackState = .playing(
            chapterIndex: currentChapterIndex,
            chunkIndex: currentChunkIndex,
            totalChunks: currentChunks.count
        )
        engine.speak(chunk: chunk, voiceIdentifier: voiceIdentifier, rate: rate)
    }

    private func advanceToNextChapter(autoPlay: Bool) {
        guard let next = delegate?.speechCoordinatorRequestsNextChapter(self, afterChapter: currentChapterIndex) else {
            stop()
            return
        }
        let chunks = ChapterSearch.speechChunks(from: next.text)
        guard !chunks.isEmpty else {
            currentChapterIndex = next.chapterIndex
            advanceToNextChapter(autoPlay: autoPlay)
            return
        }
        currentChapterIndex = next.chapterIndex
        currentChunks = chunks
        currentChunkIndex = 0
        updateChunkPosition(wasPlaying: autoPlay)
    }

    fileprivate func handleUtteranceFinished() {
        guard playbackState.isPlaying else { return }
        if currentChunkIndex + 1 < currentChunks.count {
            currentChunkIndex += 1
            playCurrentChunk()
        } else {
            advanceToNextChapter(autoPlay: true)
        }
    }
}

// MARK: - TTSEngineDelegate

extension SpeechCoordinator: TTSEngineDelegate {
    func ttsEngineDidStartUtterance(_ engine: TTSEngine) {
        // Maintained by playCurrentChunk
    }

    func ttsEngineDidFinishUtterance(_ engine: TTSEngine) {
        handleUtteranceFinished()
    }

    func ttsEngine(_ engine: TTSEngine, willSpeakWordRange range: Range<String.Index>, in text: String) {
        delegate?.speechCoordinator(
            self,
            willSpeakWordRange: range,
            inChunk: text,
            chapterIndex: currentChapterIndex
        )
    }
}
