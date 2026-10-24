//
//  TTSEngine.swift
//  Honeycrisp
//
//  Created on 2026-10-23.
//

import Foundation

/// Quality tier for voice representation.
public enum TTSVoiceQuality: Int, Comparable, Sendable {
    case standard = 1
    case enhanced = 2
    case premium = 3

    public static func < (lhs: TTSVoiceQuality, rhs: TTSVoiceQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Generic voice descriptor decoupled from concrete audio frameworks.
public struct TTSVoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: TTSVoiceQuality

    public init(id: String, name: String, language: String, quality: TTSVoiceQuality) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }

    public var displayName: String {
        let badge: String
        switch quality {
        case .premium: badge = " [Premium]"
        case .enhanced: badge = " [Enhanced]"
        case .standard: badge = ""
        }
        return "\(name)\(badge) (\(language))"
    }
}

/// Delegate protocol for speech synthesis backends.
@MainActor
public protocol TTSEngineDelegate: AnyObject {
    func ttsEngineDidStartUtterance(_ engine: TTSEngine)
    func ttsEngineDidFinishUtterance(_ engine: TTSEngine)
    func ttsEngine(_ engine: TTSEngine, willSpeakWordRange range: Range<String.Index>, in text: String)
}

/// Protocol defining a speech synthesis engine backend.
@MainActor
public protocol TTSEngine: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var availableVoices: [TTSVoice] { get }
    var preferredVoiceIdentifier: String? { get }
    var delegate: TTSEngineDelegate? { get set }

    func speak(
        chunk: String,
        voiceIdentifier: String?,
        rate: Float
    )

    func pause()
    func resume()
    func stop()
}
