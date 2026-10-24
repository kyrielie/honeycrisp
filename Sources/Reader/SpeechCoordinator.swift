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

private final class UtteranceTask: Equatable {
    let id = UUID()
    let chapterIndex: Int, chunkIndex: Int, totalChunks: Int, text: String
    var isCancelled: Bool = false
    init(chapterIndex: Int, chunkIndex: Int, totalChunks: Int, text: String) {
        self.chapterIndex = chapterIndex
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.text = text
    }
    static func == (lhs: UtteranceTask, rhs: UtteranceTask) -> Bool { lhs.id == rhs.id }
}

private final class TaskUtterance: AVSpeechUtterance {
    let task: UtteranceTask
    init(task: UtteranceTask) {
        self.task = task
        super.init(string: task.text)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Orchestrates text-to-speech reading with sentence chunking, deadlock-free AVFoundation state machine,
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
    private let synthesizer = AVSpeechSynthesizer()
    private var currentChapterIndex: Int = 0, currentChunks: [String] = [], currentChunkIndex: Int = 0

    private enum EngineState: Equatable {
        case stopped
        case starting(UtteranceTask)
        case playing(UtteranceTask)
        case stopping(UtteranceTask, queued: UtteranceTask?)
    }

    private enum EngineEvent: Equatable {
        case play(UtteranceTask)
        case stop
        case didStart(UtteranceTask)
        case didFinish(UtteranceTask)
    }

    private var engineState: EngineState = .stopped

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    public static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                if #available(macOS 14.0, *) {
                    if voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) {
                        return false
                    }
                }
                return !voice.identifier.contains(".eloquence.")
                    && !voice.identifier.starts(with: "com.apple.speech.synthesis.voice.")
            }
            .sorted { v1, v2 in
                let q1 = qualityRank(v1.quality), q2 = qualityRank(v2.quality)
                if q1 != q2 { return q1 > q2 }
                return v1.name.localizedCaseInsensitiveCompare(v2.name) == .orderedAscending
            }
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    public static func displayName(for voice: AVSpeechSynthesisVoice) -> String {
        let badge: String
        switch voice.quality {
        case .premium: badge = " [Premium]"
        case .enhanced: badge = " [Enhanced]"
        default: badge = ""
        }
        return "\(voice.name)\(badge) (\(voice.language))"
    }

    public static var preferredVoiceIdentifier: String? {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let matching = availableVoices.filter { $0.language.lowercased().starts(with: code.lowercased()) }
        return matching.first?.identifier ?? availableVoices.first?.identifier
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
        onEngineEvent(.stop)
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
        onEngineEvent(.stop)
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
        let task = UtteranceTask(
            chapterIndex: currentChapterIndex,
            chunkIndex: currentChunkIndex,
            totalChunks: currentChunks.count,
            text: chunk
        )
        playbackState = .playing(
            chapterIndex: currentChapterIndex,
            chunkIndex: currentChunkIndex,
            totalChunks: currentChunks.count
        )
        onEngineEvent(.play(task))
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

    private func handleUtteranceFinished(_ task: UtteranceTask) {
        guard task.chapterIndex == currentChapterIndex, task.chunkIndex == currentChunkIndex else { return }
        if currentChunkIndex + 1 < currentChunks.count {
            currentChunkIndex += 1
            playCurrentChunk()
        } else {
            advanceToNextChapter(autoPlay: true)
        }
    }

    private func onEngineEvent(_ event: EngineEvent) {
        switch engineState {
        case .stopped:
            if case let .play(task) = event {
                engineState = .starting(task)
                startSynthesizer(with: task)
            }
        case let .starting(current): handleStarting(event: event, current: current)
        case let .playing(current): handlePlaying(event: event, current: current)
        case let .stopping(current, queued): handleStopping(event: event, current: current, queued: queued)
        }
    }

    private func handleStarting(event: EngineEvent, current: UtteranceTask) {
        switch event {
        case let .didStart(task) where current == task: engineState = .playing(current)
        case let .didFinish(task) where current == task:
            engineState = .stopped
            if playbackState.isPlaying { handleUtteranceFinished(current) }
        case let .play(next):
            engineState = .stopping(current, queued: next)
            synthesizer.stopSpeaking(at: .immediate)
        case .stop:
            engineState = .stopping(current, queued: nil)
            synthesizer.stopSpeaking(at: .immediate)
        default: break
        }
    }

    private func handlePlaying(event: EngineEvent, current: UtteranceTask) {
        switch event {
        case let .didFinish(task) where current == task:
            engineState = .stopped
            if playbackState.isPlaying { handleUtteranceFinished(current) }
        case let .play(next):
            engineState = .stopping(current, queued: next)
            synthesizer.stopSpeaking(at: .immediate)
        case .stop:
            engineState = .stopping(current, queued: nil)
            synthesizer.stopSpeaking(at: .immediate)
        default: break
        }
    }

    private func handleStopping(event: EngineEvent, current: UtteranceTask, queued: UtteranceTask?) {
        switch event {
        case let .didStart(task) where current == task: synthesizer.stopSpeaking(at: .immediate)
        case let .didFinish(task) where current == task:
            if let next = queued, !next.isCancelled {
                engineState = .starting(next)
                startSynthesizer(with: next)
            } else { engineState = .stopped }
        case let .play(next): engineState = .stopping(current, queued: next)
        case .stop: engineState = .stopping(current, queued: nil)
        default: break
        }
    }

    private func startSynthesizer(with task: UtteranceTask) {
        let utterance = TaskUtterance(task: task)
        utterance.rate = rate
        utterance.preUtteranceDelay = 0.08
        utterance.postUtteranceDelay = 0.04
        let chosenID = voiceIdentifier ?? Self.preferredVoiceIdentifier
        if let chosenID, !chosenID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: chosenID)
        }
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechCoordinator: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let task = (utterance as? TaskUtterance)?.task else { return }
        onEngineEvent(.didStart(task))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let task = (utterance as? TaskUtterance)?.task else { return }
        onEngineEvent(.didFinish(task))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let task = (utterance as? TaskUtterance)?.task else { return }
        onEngineEvent(.didFinish(task))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard
            let task = (utterance as? TaskUtterance)?.task,
            characterRange.upperBound <= task.text.count,
            let range = Range(characterRange, in: task.text)
        else { return }

        delegate?.speechCoordinator(
            self,
            willSpeakWordRange: range,
            inChunk: task.text,
            chapterIndex: task.chapterIndex
        )
    }
}
