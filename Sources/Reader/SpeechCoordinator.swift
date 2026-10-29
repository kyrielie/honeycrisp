//
//  SpeechCoordinator.swift
//  Honeycrisp
//
//  Created on 2026-10-23.
//

import AVFoundation
import Foundation

struct SpeechProgress: Equatable, Sendable {
    let chapterIndex: Int
    let sentenceChapterRange: Range<Int>
    let wordChapterRange: Range<Int>?

    init(
        chapterIndex: Int,
        sentenceChapterRange: Range<Int>,
        wordChapterRange: Range<Int>? = nil
    ) {
        self.chapterIndex = chapterIndex
        self.sentenceChapterRange = sentenceChapterRange
        self.wordChapterRange = wordChapterRange
    }
}

@MainActor
protocol SpeechCoordinatorDelegate: AnyObject {
    func speechCoordinator(_ coordinator: SpeechCoordinator, didChangeState state: SpeechCoordinator.PlaybackState)
    func speechCoordinator(_ coordinator: SpeechCoordinator, didAdvanceTo progress: SpeechProgress)
    func speechCoordinator(_ coordinator: SpeechCoordinator, willBeginChapter chapterIndex: Int)
    func speechCoordinator(
        _ coordinator: SpeechCoordinator,
        willSpeakWordRange range: Range<String.Index>,
        inChunk chunk: String,
        chapterIndex: Int
    )
    func speechCoordinatorRequestsNextChapter(
        _ coordinator: SpeechCoordinator,
        afterChapter chapterIndex: Int
    ) -> (chapterIndex: Int, map: SpeechTextMap)?
    func speechCoordinatorRequestsPreviousChapter(
        _ coordinator: SpeechCoordinator,
        beforeChapter chapterIndex: Int
    ) -> (chapterIndex: Int, map: SpeechTextMap)?
}

extension SpeechCoordinatorDelegate {
    func speechCoordinator(_ coordinator: SpeechCoordinator, didAdvanceTo progress: SpeechProgress) {}
    func speechCoordinator(_ coordinator: SpeechCoordinator, willBeginChapter chapterIndex: Int) {}
    func speechCoordinator(
        _ coordinator: SpeechCoordinator,
        willSpeakWordRange range: Range<String.Index>,
        inChunk chunk: String,
        chapterIndex: Int
    ) {}
    func speechCoordinatorRequestsPreviousChapter(
        _ coordinator: SpeechCoordinator,
        beforeChapter chapterIndex: Int
    ) -> (chapterIndex: Int, map: SpeechTextMap)? { nil }
}

/// Orchestrates text-to-speech reading with sentence chunking, pluggable TTSEngine backend,
/// automatic spine item auto-advance, and skip navigation.
@MainActor
final class SpeechCoordinator: NSObject {
    enum PlaybackState: Equatable, Sendable {
        case idle
        case playing(chapterIndex: Int, chunkIndex: Int, totalChunks: Int)
        case paused(chapterIndex: Int, chunkIndex: Int, totalChunks: Int)

        var isPlaying: Bool { if case .playing = self { return true } else { return false } }
        var isPaused: Bool { if case .paused = self { return true } else { return false } }
        var isIdle: Bool { if case .idle = self { return true } else { return false } }
    }

    weak var delegate: SpeechCoordinatorDelegate?

    private(set) var playbackState: PlaybackState = .idle {
        didSet {
            if oldValue != playbackState { delegate?.speechCoordinator(self, didChangeState: playbackState) }
        }
    }

    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var voiceIdentifier: String?

    var engine: TTSEngine {
        didSet {
            let wasPlaying = playbackState.isPlaying
            oldValue.stop()
            engine.delegate = self
            if wasPlaying { playCurrentChunk() }
        }
    }

    private var currentChapterIndex: Int = 0
    private var currentMap: SpeechTextMap = SpeechTextMap(text: "", chapterOffsets: [])
    private var currentSentences: [SpeechSentence] = []
    private var currentChunkIndex: Int = 0

    init(engine: TTSEngine? = nil) {
        let activeEngine = engine ?? AVFoundationTTSEngine()
        self.engine = activeEngine
        super.init()
        self.engine.delegate = self
    }

    var availableVoices: [TTSVoice] {
        engine.availableVoices
    }

    static var defaultVoices: [TTSVoice] {
        AVFoundationTTSEngine().availableVoices
    }

    var preferredVoiceIdentifier: String? {
        engine.preferredVoiceIdentifier
    }

    static func displayName(for voice: TTSVoice) -> String {
        voice.displayName
    }

    func start(chapterIndex: Int, map: SpeechTextMap, fromChapterOffset offset: Int = 0) {
        let sentences = map.sentences()
        guard !sentences.isEmpty else { stop(); return }
        currentChapterIndex = chapterIndex
        currentMap = map
        currentSentences = sentences
        currentChunkIndex = map.sentenceIndex(containingOrAfter: offset) ?? max(0, sentences.count - 1)
        delegate?.speechCoordinator(self, willBeginChapter: chapterIndex)
        playCurrentChunk()
    }

    func start(chapterIndex: Int, text: String) {
        start(chapterIndex: chapterIndex, map: SpeechTextMap(plainText: text), fromChapterOffset: 0)
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
        currentMap = SpeechTextMap(text: "", chapterOffsets: [])
        currentSentences = []
        currentChunkIndex = 0
        engine.stop()
    }

    func skipNext() {
        guard !currentSentences.isEmpty else { return }
        let wasPlaying = playbackState.isPlaying
        if currentChunkIndex + 1 < currentSentences.count {
            currentChunkIndex += 1
            updateChunkPosition(wasPlaying: wasPlaying)
        } else {
            advanceToNextChapter(autoPlay: wasPlaying)
        }
    }

    func skipPrevious() {
        guard !currentSentences.isEmpty else { return }
        let wasPlaying = playbackState.isPlaying
        if currentChunkIndex > 0 {
            currentChunkIndex -= 1
            updateChunkPosition(wasPlaying: wasPlaying)
        } else if let prev = delegate?.speechCoordinatorRequestsPreviousChapter(
            self,
            beforeChapter: currentChapterIndex
        ) {
            let sentences = prev.map.sentences()
            guard !sentences.isEmpty else { return }
            currentChapterIndex = prev.chapterIndex
            currentMap = prev.map
            currentSentences = sentences
            currentChunkIndex = max(0, sentences.count - 1)
            delegate?.speechCoordinator(self, willBeginChapter: prev.chapterIndex)
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
                totalChunks: currentSentences.count
            )
        }
    }

    private func playCurrentChunk() {
        guard currentSentences.indices.contains(currentChunkIndex) else {
            advanceToNextChapter(autoPlay: true)
            return
        }
        let sentence = currentSentences[currentChunkIndex]
        playbackState = .playing(
            chapterIndex: currentChapterIndex,
            chunkIndex: currentChunkIndex,
            totalChunks: currentSentences.count
        )
        let progress = SpeechProgress(
            chapterIndex: currentChapterIndex,
            sentenceChapterRange: sentence.chapterStart..<sentence.chapterEnd,
            wordChapterRange: nil
        )
        delegate?.speechCoordinator(self, didAdvanceTo: progress)
        engine.speak(chunk: sentence.text, voiceIdentifier: voiceIdentifier, rate: rate)
    }

    private func advanceToNextChapter(autoPlay: Bool) {
        guard let next = delegate?.speechCoordinatorRequestsNextChapter(self, afterChapter: currentChapterIndex) else {
            stop()
            return
        }
        let sentences = next.map.sentences()
        guard !sentences.isEmpty else {
            currentChapterIndex = next.chapterIndex
            advanceToNextChapter(autoPlay: autoPlay)
            return
        }
        currentChapterIndex = next.chapterIndex
        currentMap = next.map
        currentSentences = sentences
        currentChunkIndex = 0
        delegate?.speechCoordinator(self, willBeginChapter: next.chapterIndex)
        updateChunkPosition(wasPlaying: autoPlay)
    }

    fileprivate func handleUtteranceFinished() {
        guard playbackState.isPlaying else { return }
        if currentChunkIndex + 1 < currentSentences.count {
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

        guard currentSentences.indices.contains(currentChunkIndex) else { return }
        let sentence = currentSentences[currentChunkIndex]
        let ns = NSRange(range, in: text)
        guard ns.location != NSNotFound, ns.length > 0 else { return }

        let spokenWordStart = sentence.spoken.location + ns.location
        let spokenWordEnd = spokenWordStart + ns.length
        guard spokenWordStart < currentMap.chapterOffsets.count,
              spokenWordEnd <= currentMap.chapterOffsets.count else { return }

        let chapterWordStart = currentMap.chapterOffsets[spokenWordStart]
        let chapterWordEnd = currentMap.chapterOffsets[spokenWordEnd - 1] + 1
        let progress = SpeechProgress(
            chapterIndex: currentChapterIndex,
            sentenceChapterRange: sentence.chapterStart..<sentence.chapterEnd,
            wordChapterRange: chapterWordStart..<chapterWordEnd
        )
        delegate?.speechCoordinator(self, didAdvanceTo: progress)
    }
}
