import Foundation
import XCTest
@testable import Honeycrisp

final class ChapterPipelineConcurrencyTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterPipelineConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ChapterPipeline.maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testConcurrentRenderIsByteIdenticalToSequential() throws {
        let chapterFiles = try generateSyntheticChapters(count: 64)
        defer { ChapterPipeline.maxConcurrency = ProcessInfo.processInfo.activeProcessorCount }

        for _ in 0..<8 {
            ChapterPipeline.maxConcurrency = 1
            let sequential = try ChapterPipeline.renderAll(count: chapterFiles.count) { index in
                try ChapterPipeline.render(
                    chapterAt: chapterFiles[index],
                    mediaType: "application/xhtml+xml",
                    resource: index,
                    root: self.temporaryDirectory
                )
            }

            ChapterPipeline.maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
            let concurrent = try ChapterPipeline.renderAll(count: chapterFiles.count) { index in
                try ChapterPipeline.render(
                    chapterAt: chapterFiles[index],
                    mediaType: "application/xhtml+xml",
                    resource: index,
                    root: self.temporaryDirectory
                )
            }

            XCTAssertEqual(concurrent, sequential, "Concurrent render output must be byte-identical to sequential")
        }
    }

    func testErrorFromLowestIndexIsRethrown() {
        struct TestError: Error, Equatable {
            let index: Int
        }

        XCTAssertThrowsError(
            try ChapterPipeline.renderAll(count: 20) { index -> String in
                if index == 15 || index == 5 || index == 10 {
                    throw TestError(index: index)
                }
                return "ok_\(index)"
            }
        ) { error in
            guard let testError = error as? TestError else {
                XCTFail("Expected TestError, got \(error)")
                return
            }
            XCTAssertEqual(testError.index, 5, "Lowest index error must be rethrown")
        }
    }

    func testResultsAreInIndexOrder() throws {
        let count = 100
        let results = try ChapterPipeline.renderAll(count: count) { index -> Int in
            usleep(useconds_t.random(in: 10...200))
            return index
        }
        XCTAssertEqual(results, Array(0..<count), "Results must strictly preserve index order")
    }

    private func generateSyntheticChapters(count: Int) throws -> [URL] {
        var urls: [URL] = []
        for i in 0..<count {
            let content = """
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>Chapter \(i)</title></head>
                <body>
                    <h1>Heading \(i)</h1>
                    <p>Paragraph 1 with &amp; entities and \u{00E9} accent.</p>
                    <p>Paragraph 2 with <a href="next.xhtml">link</a>.</p>
                </body>
                </html>
                """
            let fileURL = temporaryDirectory.appendingPathComponent("ch_\(i).xhtml")
            try Data(content.utf8).write(to: fileURL)
            urls.append(fileURL)
        }
        return urls
    }
}
