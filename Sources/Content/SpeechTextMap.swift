//
//  SpeechTextMap.swift
//  Honeycrisp
//
//  Created on 2026-10-28.
//

import Foundation

struct SpeechSentence: Equatable, Sendable {
    let spoken: NSRange
    let text: String
    let chapterStart: Int
    let chapterEnd: Int

    init(spoken: NSRange, text: String, chapterStart: Int, chapterEnd: Int) {
        self.spoken = spoken
        self.text = text
        self.chapterStart = chapterStart
        self.chapterEnd = chapterEnd
    }
}

struct SpeechTextMap: Equatable, Sendable {
    let text: String
    let chapterOffsets: [Int]

    init(text: String, chapterOffsets: [Int]) {
        self.text = text
        self.chapterOffsets = chapterOffsets
    }

    init(plainText: String) {
        self.text = plainText
        let nsLen = (plainText as NSString).length
        self.chapterOffsets = Array(0..<nsLen)
    }

    // swiftlint:disable:next function_body_length
    static func make(from chapterText: ChapterText) -> SpeechTextMap {
        let nsString = chapterText.string as NSString
        let totalUnits = nsString.length
        guard totalUnits > 0 else {
            return SpeechTextMap(text: "", chapterOffsets: [])
        }

        let skipSet = chapterText.speechSkipRanges
        let blockBreaksSet = Set(chapterText.blockBreaks)
        let whitespace = CharacterSet.whitespacesAndNewlines

        var outputScalars: [unichar] = []
        var offsets: [Int] = []
        outputScalars.reserveCapacity(totalUnits)
        offsets.reserveCapacity(totalUnits)

        var pendingBreak = false
        var pendingSpace = false

        var i = 0
        while i < totalUnits {
            // Check if within any skip range
            var isSkipped = false
            for range in skipSet {
                if i >= range.location && i < range.location + range.length {
                    isSkipped = true
                    pendingSpace = true
                    i = range.location + range.length
                    break
                }
            }
            if isSkipped { continue }

            if blockBreaksSet.contains(i) {
                pendingBreak = true
            }

            let ch = nsString.character(at: i)
            if let scalar = Unicode.Scalar(ch), whitespace.contains(scalar) {
                pendingSpace = true
                i += 1
                continue
            }

            // Real character
            if !outputScalars.isEmpty {
                if pendingBreak {
                    outputScalars.append(0x000A) // '\n'
                    offsets.append(i)
                } else if pendingSpace {
                    outputScalars.append(0x0020) // ' '
                    offsets.append(i)
                }
            }
            pendingBreak = false
            pendingSpace = false

            outputScalars.append(ch)
            offsets.append(i)
            i += 1
        }

        let outText = String(utf16CodeUnits: outputScalars, count: outputScalars.count)
        return SpeechTextMap(text: outText, chapterOffsets: offsets)
    }

    func sentences() -> [SpeechSentence] {
        guard !text.isEmpty, !chapterOffsets.isEmpty else { return [] }
        let ranges = ChapterSearch.speechChunkRanges(in: text)
        var result: [SpeechSentence] = []
        result.reserveCapacity(ranges.count)

        let nsText = text as NSString
        for range in ranges {
            guard range.length > 0,
                  range.location < chapterOffsets.count,
                  NSMaxRange(range) <= chapterOffsets.count else { continue }
            let sentenceText = nsText.substring(with: range)
            let chapterStart = chapterOffsets[range.location]
            let chapterEnd = chapterOffsets[NSMaxRange(range) - 1] + 1
            result.append(SpeechSentence(
                spoken: range,
                text: sentenceText,
                chapterStart: chapterStart,
                chapterEnd: chapterEnd
            ))
        }
        return result
    }

    func spokenIndex(forChapterOffset chapterOffset: Int) -> Int {
        guard !chapterOffsets.isEmpty else { return 0 }
        var low = 0
        var high = chapterOffsets.count - 1
        var best = chapterOffsets.count - 1

        while low <= high {
            let mid = (low + high) / 2
            if chapterOffsets[mid] >= chapterOffset {
                best = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return best
    }

    func sentenceIndex(containingOrAfter chapterOffset: Int) -> Int? {
        let all = sentences()
        guard !all.isEmpty else { return nil }

        for (idx, sentence) in all.enumerated() where chapterOffset < sentence.chapterEnd {
            return idx
        }
        return nil
    }
}
