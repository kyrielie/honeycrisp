//
//  SpeechStartResolver.swift
//  Honeycrisp
//
//  Created on 2026-10-28.
//

import Foundation

enum SpeechStartSource: String, Equatable, Sendable {
    case selection
    case viewport
    case point
    case start
}

enum SpeechStartResolver {
    static func sentenceIndex(
        in sentences: [SpeechSentence],
        caretOffset: Int,
        source: SpeechStartSource,
        nextStartIsOnScreen: Bool = true
    ) -> Int? {
        guard !sentences.isEmpty else { return nil }

        switch source {
        case .selection, .point:
            for (idx, sentence) in sentences.enumerated() where caretOffset < sentence.chapterEnd {
                return idx
            }
            return sentences.count - 1

        case .viewport:
            for (idx, sentence) in sentences.enumerated() {
                if sentence.chapterStart >= caretOffset {
                    return nextStartIsOnScreen ? idx : max(0, idx - 1)
                }
                if caretOffset < sentence.chapterEnd {
                    return idx
                }
            }
            return sentences.count - 1

        case .start:
            return 0
        }
    }
}
