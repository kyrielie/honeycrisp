import Foundation
import XCTest
@testable import Honeycrisp

final class ChapterPipelineThroughputTests: XCTestCase {
    private var temporaryDirectory: URL!

    private static let testCosmetics = ReaderCosmeticSettings(
        fontSizePercent: 100, fontFamily: "Charter, Georgia, serif", backgroundCSS: "#ffffff",
        textCSS: "#000000", linkCSS: "#0068da", hitBackground: "#ffee58", hitText: "#000000",
        hitActiveBackground: "#ffa000", hitActiveText: "#000000", lineHeight: 1.6, maxWidth: 700,
        paddingH: 24, allowLinkClicks: true, overrideMonospace: true, textAlignment: .book,
        hyphenate: false, language: nil, paragraphSpacing: 0, paragraphIndent: nil, boldWeight: .book
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterPipelineThroughputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ChapterPipeline.maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testThroughputIsRecorded() throws {
        let singleMs = try benchmark150KBChapter()
        let (seqMs, concMs, searchMs) = try benchmark300Chapters()
        let scrollMs = try benchmark2000PagesScroll()

        let lines = [
            "activeProcessorCount: \(ProcessInfo.processInfo.activeProcessorCount)",
            "singleChapter150KBRenderMs: \(String(format: "%.1f", singleMs))",
            "renderAll300ChaptersSequentialMs: \(String(format: "%.1f", seqMs))",
            "renderAll300ChaptersConcurrentMs: \(String(format: "%.1f", concMs))",
            "searchResults300ChaptersMs: \(String(format: "%.1f", searchMs))",
            "buildFlowDocument2000PagesMs: \(String(format: "%.1f", scrollMs))",
        ]
        try TestDiagnostics.write("pipeline-throughput.txt", lines: lines)
    }

    private func benchmark150KBChapter() throws -> Double {
        let paragraph = "<p>Standard body paragraph with &amp; entities, some words, and text formatting.</p>\n"
        let content = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n"
            + String(repeating: paragraph, count: 1800)
            + "</body></html>\n"
        let fileURL = temporaryDirectory.appendingPathComponent("chapter150kb.xhtml")
        try Data(content.utf8).write(to: fileURL)

        var runs: [Double] = []
        for _ in 0..<3 {
            let (_, ms) = try timeBlock {
                try ChapterPipeline.render(
                    chapterAt: fileURL,
                    mediaType: "application/xhtml+xml",
                    resource: 0,
                    root: self.temporaryDirectory
                )
            }
            runs.append(ms)
        }
        return median(runs)
    }

    private func benchmark300Chapters() throws -> (Double, Double, Double) {
        let bookDir = temporaryDirectory.appendingPathComponent("Book300", isDirectory: true)
        try SyntheticBook(pages: 300 * SyntheticBook.pagesPerChapter).write(to: bookDir)
        let package = try EPUBParser().parsePackage(at: bookDir)

        var seqRuns: [Double] = []
        var concRuns: [Double] = []
        var searchRuns: [Double] = []
        var lastSeqOutput: [String] = []
        var lastConcOutput: [String] = []

        defer { ChapterPipeline.maxConcurrency = ProcessInfo.processInfo.activeProcessorCount }

        for _ in 0..<3 {
            ChapterPipeline.maxConcurrency = 1
            let (seq, seqMs) = try timeBlock {
                try ChapterPipeline.renderAll(count: package.spineURLs.count) { i in
                    try ChapterPipeline.render(
                        chapterAt: package.spineURLs[i],
                        mediaType: "application/xhtml+xml",
                        resource: i,
                        root: package.rootFolder
                    )
                }
            }
            seqRuns.append(seqMs)
            lastSeqOutput = seq

            ChapterPipeline.maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
            let (conc, concMs) = try timeBlock {
                try ChapterPipeline.renderAll(count: package.spineURLs.count) { i in
                    try ChapterPipeline.render(
                        chapterAt: package.spineURLs[i],
                        mediaType: "application/xhtml+xml",
                        resource: i,
                        root: package.rootFolder
                    )
                }
            }
            concRuns.append(concMs)
            lastConcOutput = conc

            let (_, searchMs) = try timeBlock {
                EPUBParser().searchResults(for: "river", in: package)
            }
            searchRuns.append(searchMs)
        }

        XCTAssertEqual(lastConcOutput, lastSeqOutput, "Concurrent renderAll output must match sequential renderAll output")
        return (median(seqRuns), median(concRuns), median(searchRuns))
    }

    private func benchmark2000PagesScroll() throws -> Double {
        let bookDir = temporaryDirectory.appendingPathComponent("Book2000", isDirectory: true)
        try SyntheticBook(pages: 2000).write(to: bookDir)
        let package = try EPUBParser().parsePackage(at: bookDir)

        var runs: [Double] = []
        let parser = EPUBParser()
        for _ in 0..<3 {
            let (_, ms) = try timeBlock {
                try FlowDocumentBuilder.buildDocument(package: package, cosmetics: Self.testCosmetics)
            }
            runs.append(ms)
        }
        return median(runs)
    }

    private func timeBlock<T>(_ block: () throws -> T) throws -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try block()
        let end = DispatchTime.now().uptimeNanoseconds
        let ms = Double(end - start) / 1_000_000.0
        return (result, ms)
    }

    private func median(_ times: [Double]) -> Double {
        times.sorted()[times.count / 2]
    }
}
