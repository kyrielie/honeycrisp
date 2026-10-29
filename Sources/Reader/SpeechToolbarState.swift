//
//  SpeechToolbarState.swift
//  Honeycrisp
//
//  Created on 2026-10-28.
//

import Foundation

enum SpeechToolbarState: Equatable, Sendable {
    case unavailable
    case idle
    case active(paused: Bool)

    init(playback: SpeechCoordinator.PlaybackState, hasBook: Bool) {
        guard hasBook else {
            self = .unavailable
            return
        }
        switch playback {
        case .idle:
            self = .idle
        case .playing:
            self = .active(paused: false)
        case .paused:
            self = .active(paused: true)
        }
    }

    var symbolName: String {
        switch self {
        case .unavailable, .idle:
            return "speaker.wave.2"
        case .active:
            return "stop.fill"
        }
    }

    var tooltip: String {
        switch self {
        case .unavailable, .idle:
            return "Speak from selection or top of page"
        case .active(paused: false):
            return "Stop speaking (Option-click to pause)"
        case .active(paused: true):
            return "Stop speaking (Option-click to resume)"
        }
    }

    var isEnabled: Bool {
        self != .unavailable
    }
}
