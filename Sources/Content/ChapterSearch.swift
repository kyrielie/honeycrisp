// ChapterSearch.swift
// Full-book search and speech text extraction over parsed chapter content (FRAMEWORK L2 Content)

import Foundation

enum ChapterSearch {

    static func searchResults(
        for term: String,
        in package: EPUBPackage,
        limit: Int = 250,
        options: ChapterTransformOptions = .init()
    ) -> [BookSearchResult] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var results: [BookSearchResult] = []
        let texts = (try? ChapterPipeline.renderAll(count: package.spineURLs.count) { index -> ChapterText? in
            let url = package.spineURLs[index]
            let mediaType = package.spine.indices.contains(index)
                ? package.manifest[package.spine[index].manifestID]?.mediaType
                : nil
            return try? ChapterPipeline.text(
                chapterAt: url,
                mediaType: mediaType,
                resource: index,
                root: package.rootFolder,
                options: options
            )
        }) ?? []

        for (index, maybeText) in texts.enumerated() {
            guard let text = maybeText else { continue }
            let nsText = text.string as NSString
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 && results.count < limit {
                let match = nsText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard match.location != NSNotFound else { break }
                let nextLocation = NSMaxRange(match)
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)

                let intersectsHidden = text.hiddenRanges.contains { hidden in
                    NSIntersectionRange(match, hidden).length > 0
                }
                if intersectsHidden { continue }

                let before = max(0, match.location - 65)
                let after = min(nsText.length, NSMaxRange(match) + 90)
                var excerpt = nsText.substring(with: NSRange(location: before, length: after - before))
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if before > 0 { excerpt = "…" + excerpt }
                if after < nsText.length { excerpt += "…" }
                results.append(BookSearchResult(spineIndex: index, characterOffset: match.location, excerpt: excerpt))
            }
            if results.count >= limit { break }
        }
        return results
    }

    static func speechText(
        in package: EPUBPackage,
        at index: Int,
        options: ChapterTransformOptions = .init()
    ) -> String? {
        guard package.spineURLs.indices.contains(index) else { return nil }
        let url = package.spineURLs[index]
        let mediaType = package.spine.indices.contains(index)
            ? package.manifest[package.spine[index].manifestID]?.mediaType
            : nil
        guard let text = try? ChapterPipeline.text(
            chapterAt: url,
            mediaType: mediaType,
            resource: index,
            root: package.rootFolder,
            options: options
        ) else { return nil }

        let mutable = NSMutableString(string: text.string)
        for hidden in text.hiddenRanges.reversed() where hidden.location + hidden.length <= mutable.length {
            mutable.replaceCharacters(in: hidden, with: "")
        }
        return (mutable as String)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func speechMap(
        in package: EPUBPackage,
        at index: Int,
        options: ChapterTransformOptions = .init()
    ) -> SpeechTextMap? {
        guard package.spineURLs.indices.contains(index) else { return nil }
        let url = package.spineURLs[index]
        let mediaType = package.spine.indices.contains(index)
            ? package.manifest[package.spine[index].manifestID]?.mediaType
            : nil
        guard let chapterText = try? ChapterPipeline.text(
            chapterAt: url,
            mediaType: mediaType,
            resource: index,
            root: package.rootFolder,
            options: options
        ) else { return nil }

        return SpeechTextMap.make(from: chapterText)
    }

    /// Finds trimmed sentence chunk ranges in text, preserving abbreviation boundaries.
    static func speechChunkRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let abbreviations = [
            "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Sr.", "Jr.", "vs.", "etc.", "e.g.", "i.e.", "approx.", "fig.",
        ]
        var protected = text
        for abbr in abbreviations {
            guard abbr.hasSuffix(".") else { continue }
            let replacement = String(abbr.dropLast()) + "\u{E000}"
            protected = protected.replacingOccurrences(of: abbr, with: replacement)
        }

        let pattern = #"(?<=[.?!])\s+|[\r\n]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [trimmedRange(in: text, range: NSRange(location: 0, length: (text as NSString).length))]
        }

        let nsString = text as NSString
        let matches = regex.matches(in: protected, range: NSRange(location: 0, length: nsString.length))
        var ranges: [NSRange] = []
        var lastIndex = 0

        for match in matches {
            let chunkRange = NSRange(location: lastIndex, length: match.range.location - lastIndex)
            let trimmed = trimmedRange(in: text, range: chunkRange)
            if trimmed.length > 0 {
                ranges.append(trimmed)
            }
            lastIndex = match.range.location + match.range.length
        }

        if lastIndex < nsString.length {
            let chunkRange = NSRange(location: lastIndex, length: nsString.length - lastIndex)
            let trimmed = trimmedRange(in: text, range: chunkRange)
            if trimmed.length > 0 {
                ranges.append(trimmed)
            }
        }

        if ranges.isEmpty {
            let trimmed = trimmedRange(in: text, range: NSRange(location: 0, length: nsString.length))
            return trimmed.length > 0 ? [trimmed] : []
        }
        return ranges
    }

    private static func trimmedRange(in text: String, range: NSRange) -> NSRange {
        let ns = text as NSString
        guard range.location < ns.length, NSMaxRange(range) <= ns.length else { return NSRange(location: 0, length: 0) }

        var start = range.location
        var end = NSMaxRange(range)

        let whitespace = CharacterSet.whitespacesAndNewlines
        while start < end {
            let ch = ns.character(at: start)
            if let scalar = Unicode.Scalar(ch), whitespace.contains(scalar) {
                start += 1
            } else {
                break
            }
        }

        while end > start {
            let ch = ns.character(at: end - 1)
            if let scalar = Unicode.Scalar(ch), whitespace.contains(scalar) {
                end -= 1
            } else {
                break
            }
        }

        return NSRange(location: start, length: end - start)
    }

    /// Splits continuous chapter text into sentence chunks with abbreviation protection.
    static func speechChunks(from text: String) -> [String] {
        let ranges = speechChunkRanges(in: text)
        guard !ranges.isEmpty else { return [] }
        let ns = text as NSString
        return ranges.map { ns.substring(with: $0) }
    }
}
