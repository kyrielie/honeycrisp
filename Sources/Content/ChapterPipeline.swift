import Foundation
import SwiftSoup

enum ChapterPipeline {
    static var maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)

    static func renderAll<T>(count: Int, _ transform: (Int) throws -> T) throws -> [T] {
        guard count > 0 else { return [] }
        if maxConcurrency <= 1 || count <= 1 {
            var results: [T] = []
            results.reserveCapacity(count)
            for i in 0..<count {
                results.append(try transform(i))
            }
            return results
        }

        var buffer: [T?] = Array(repeating: nil, count: count)
        var caughtErrors: [Int: Error] = [:]
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                let value = try transform(index)
                lock.lock()
                buffer[index] = value
                lock.unlock()
            } catch {
                lock.lock()
                caughtErrors[index] = error
                lock.unlock()
            }
        }

        if !caughtErrors.isEmpty {
            let lowestIndex = caughtErrors.keys.sorted().first!
            throw caughtErrors[lowestIndex]!
        }

        return buffer.compactMap { $0 }
    }

    static func render(
        chapterAt url: URL,
        mediaType: String?,
        resource: Int,
        root: URL,
        options: ChapterTransformOptions = .init()
    ) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            return ""
        }
        let decoded = ChapterDecoder.decode(data).text
        let syntax = ChapterMarkup.syntax(mediaType: mediaType, pathExtension: url.pathExtension)
        guard let document = parseDocument(decoded: decoded, syntax: syntax),
              let body = try? ChapterMarkup.body(of: document) else {
            return ""
        }

        try ChapterMarkup.removeActiveContent(in: body)
        try ChapterTransforms.apply(
            options: options,
            hidePrefaceHeading: resource == 0,
            to: body
        )
        try ChapterURLs.rewrite(
            in: body,
            chapterURL: url,
            root: root
        )
        return try ChapterMarkup.bodyHTML(of: body)
    }

    static func text(
        chapterAt url: URL,
        mediaType: String?,
        resource: Int,
        root: URL? = nil,
        options: ChapterTransformOptions = .init()
    ) throws -> ChapterText {
        guard let data = try? Data(contentsOf: url) else {
            return ChapterText(string: "", hiddenRanges: [])
        }
        let decoded = ChapterDecoder.decode(data).text
        let syntax = ChapterMarkup.syntax(mediaType: mediaType, pathExtension: url.pathExtension)
        guard let document = parseDocument(decoded: decoded, syntax: syntax),
              let body = try? ChapterMarkup.body(of: document) else {
            return ChapterText(string: "", hiddenRanges: [])
        }

        try ChapterMarkup.removeActiveContent(in: body)
        try ChapterTransforms.apply(
            options: options,
            hidePrefaceHeading: resource == 0,
            to: body
        )
        let bodyHTML = try ChapterMarkup.bodyHTML(of: body)
        return try ChapterText.extract(fromServedBodyHTML: bodyHTML)
    }

    private static func parseDocument(decoded: String, syntax: ChapterMarkup.Syntax) -> Document? {
        if let doc = try? ChapterMarkup.parse(decoded, syntax: syntax) {
            return doc
        }
        return try? ChapterMarkup.parse(decoded, syntax: .html)
    }
}
