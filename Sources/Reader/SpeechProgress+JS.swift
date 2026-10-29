//
//  SpeechProgress+JS.swift
//  Honeycrisp
//
//  Created on 2026-10-28.
//

import Foundation

extension SpeechProgress {
    func highlightJS(includeWord: Bool, follow: Bool) -> String {
        let sStart = sentenceChapterRange.lowerBound
        let sEnd = sentenceChapterRange.upperBound
        let wStart: Int
        let wEnd: Int
        if includeWord, let word = wordChapterRange {
            wStart = word.lowerBound
            wEnd = word.upperBound
        } else {
            wStart = -1
            wEnd = -1
        }
        let followFlag = follow ? 1 : 0
        return "window.honeycrispSpeechHighlight(\(chapterIndex), \(sStart), \(sEnd), \(wStart), \(wEnd), \(followFlag));"
    }
}
