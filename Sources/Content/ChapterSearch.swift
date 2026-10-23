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
}
