//
//  AVFoundationTTSEngine.swift
//  Honeycrisp
//
//  Created on 2026-10-23.
//

import AVFoundation
import Foundation

private final class UtteranceTask: Equatable {
    let id = UUID()
    let text: String
    var isCancelled: Bool = false

    init(text: String) {
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

/// TTSEngine implementation backed by Apple's native AVSpeechSynthesizer.
/// Incorporates a 4-state engine to prevent deadlocks and prioritizes Premium/Enhanced neural voices.
@MainActor
final class AVFoundationTTSEngine: NSObject, TTSEngine {
    let identifier = "com.apple.speech.avfoundation"
    let displayName = "Apple System Voices"

    weak var delegate: TTSEngineDelegate?

    private let synthesizer = AVSpeechSynthesizer()

    private enum EngineState: Equatable {
        case stopped
        case starting(UtteranceTask)
        case playing(UtteranceTask)
        case stopping(UtteranceTask, queued: UtteranceTask?)
    }

    private enum EngineEvent: Equatable {
        case play(UtteranceTask, voiceID: String?, rate: Float)
        case stop
        case didStart(UtteranceTask)
        case didFinish(UtteranceTask)
    }

    private var engineState: EngineState = .stopped
    private var queuedVoiceID: String?
    private var queuedRate: Float = AVSpeechUtteranceDefaultSpeechRate

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    public var availableVoices: [TTSVoice] {
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
            .map { voice in
                TTSVoice(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: Self.mapQuality(voice.quality)
                )
            }
            .sorted { v1, v2 in
                if v1.quality != v2.quality { return v1.quality > v2.quality }
                return v1.name.localizedCaseInsensitiveCompare(v2.name) == .orderedAscending
            }
    }

    public var preferredVoiceIdentifier: String? {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let matching = availableVoices.filter { $0.language.lowercased().starts(with: code.lowercased()) }
        return matching.first?.id ?? availableVoices.first?.id
    }

    private static func mapQuality(_ quality: AVSpeechSynthesisVoiceQuality) -> TTSVoiceQuality {
        switch quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }

    func speak(chunk: String, voiceIdentifier: String?, rate: Float) {
        let task = UtteranceTask(text: chunk)
        onEngineEvent(.play(task, voiceID: voiceIdentifier, rate: rate))
    }

    func pause() {
        onEngineEvent(.stop)
    }

    func resume() {
        // Resume is handled at coordinator level by re-calling speak with active chunk
    }

    func stop() {
        onEngineEvent(.stop)
    }

    private func onEngineEvent(_ event: EngineEvent) {
        switch engineState {
        case .stopped:
            if case let .play(task, voiceID, rate) = event {
                engineState = .starting(task)
                startSynthesizer(with: task, voiceID: voiceID, rate: rate)
            }
        case let .starting(current): handleStarting(event: event, current: current)
        case let .playing(current): handlePlaying(event: event, current: current)
        case let .stopping(current, queued): handleStopping(event: event, current: current, queued: queued)
        }
    }

    private func handleStarting(event: EngineEvent, current: UtteranceTask) {
        switch event {
        case let .didStart(task) where current == task:
            engineState = .playing(current)
            delegate?.ttsEngineDidStartUtterance(self)
        case let .didFinish(task) where current == task:
            engineState = .stopped
            delegate?.ttsEngineDidFinishUtterance(self)
        case let .play(next, voiceID, rate):
            queuedVoiceID = voiceID
            queuedRate = rate
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
            delegate?.ttsEngineDidFinishUtterance(self)
        case let .play(next, voiceID, rate):
            queuedVoiceID = voiceID
            queuedRate = rate
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
        case let .didStart(task) where current == task:
            synthesizer.stopSpeaking(at: .immediate)
        case let .didFinish(task) where current == task:
            if let next = queued, !next.isCancelled {
                engineState = .starting(next)
                startSynthesizer(with: next, voiceID: queuedVoiceID, rate: queuedRate)
            } else {
                engineState = .stopped
            }
        case let .play(next, voiceID, rate):
            queuedVoiceID = voiceID
            queuedRate = rate
            engineState = .stopping(current, queued: next)
        case .stop:
            engineState = .stopping(current, queued: nil)
        default: break
        }
    }

    private func startSynthesizer(with task: UtteranceTask, voiceID: String?, rate: Float) {
        let utterance = TaskUtterance(task: task)
        utterance.rate = rate
        utterance.preUtteranceDelay = 0.08
        utterance.postUtteranceDelay = 0.04
        let chosenID = voiceID ?? preferredVoiceIdentifier
        if let chosenID, !chosenID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: chosenID)
        }
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AVFoundationTTSEngine: @preconcurrency AVSpeechSynthesizerDelegate {
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

        delegate?.ttsEngine(self, willSpeakWordRange: range, in: task.text)
    }
}
