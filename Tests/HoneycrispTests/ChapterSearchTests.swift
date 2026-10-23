import Foundation
import XCTest
@testable import Honeycrisp

final class ChapterSearchTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    private func makePackage(chapters: [String]) throws -> EPUBPackage {
        var spineURLs: [URL] = []
        var manifest: [String: EPUBManifestItem] = [:]
        var spine: [EPUBSpineItem] = []

        for (index, content) in chapters.enumerated() {
            let filename = "chapter_\(index).xhtml"
            let fileURL = temporaryDirectory.appendingPathComponent(filename)
            try Data(content.utf8).write(to: fileURL)
            spineURLs.append(fileURL)
            let itemID = "item_\(index)"
            manifest[itemID] = EPUBManifestItem(
                id: itemID,
                href: filename,
                mediaType: "application/xhtml+xml",
                properties: [],
                url: fileURL
            )
            spine.append(EPUBSpineItem(manifestID: itemID, url: fileURL, isLinear: true))
        }

        return EPUBPackage(
            rootFolder: temporaryDirectory,
            spineURLs: spineURLs,
            title: "Test Book",
            author: "Test Author",
            coverURL: nil,
            manifest: manifest,
            spine: spine
        )
    }

    func testSearchOffsetsEqualRenderedOffsetsWhenAO3FormattingIsOn() throws {
        let chapter = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <div id="preface">
                <h2 class="toc-heading">Table of Contents</h2>
                <p><b class="calibre2">Chapter 1</b></p>
            </div>
            <p>Body paragraph with FINDME marker.</p>
            </body></html>
            """
        let package = try makePackage(chapters: [chapter])
        let options = ChapterTransformOptions(formatAO3: true)

        let results = EPUBParser().searchResults(for: "FINDME", in: package, options: options)
        XCTAssertEqual(results.count, 1)
        let searchOffset = try XCTUnwrap(results.first?.characterOffset)

        let bodyHTML = try ChapterPipeline.render(
            chapterAt: package.spineURLs[0],
            mediaType: "application/xhtml+xml",
            resource: 0,
            root: package.rootFolder,
            options: options
        )
        let renderedText = try ChapterText.extract(fromServedBodyHTML: bodyHTML)
        let renderedOffset = (renderedText.string as NSString).range(of: "FINDME").location

        XCTAssertEqual(searchOffset, renderedOffset)
    }

    func testSearchSkipsMatchesInHiddenPrefaceAndTocHeading() throws {
        let chapter0 = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
                <h1>Preface</h1>
                <h2 class="toc-heading">Contents</h2>
                <p>Visible content here.</p>
            </body></html>
            """
        let chapter1 = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
                <h1>Preface</h1>
                <p>Chapter 1 text.</p>
            </body></html>
            """
        let package = try makePackage(chapters: [chapter0, chapter1])
        let options = ChapterTransformOptions(formatAO3: true)

        let contentsResults = EPUBParser().searchResults(for: "Contents", in: package, options: options)
        XCTAssertTrue(contentsResults.isEmpty, "Search should skip toc-heading when formatAO3 is enabled")

        let prefaceResults = EPUBParser().searchResults(for: "Preface", in: package, options: options)
        XCTAssertEqual(prefaceResults.count, 1, "Preface heading in resource 0 should be skipped, but resource 1 preserved")
        XCTAssertEqual(prefaceResults.first?.spineIndex, 1)

        let visibleResults = EPUBParser().searchResults(for: "Visible", in: package, options: options)
        XCTAssertEqual(visibleResults.count, 1)
        XCTAssertEqual(visibleResults.first?.spineIndex, 0)
    }

    func testSpeechTextOmitsHiddenText() throws {
        let chapter = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
                <h1>Preface</h1>
                <h2 class="toc-heading">Contents</h2>
                <p>Visible speech text.</p>
            </body></html>
            """
        let package = try makePackage(chapters: [chapter])
        let options = ChapterTransformOptions(formatAO3: true)

        let speech = try XCTUnwrap(EPUBParser().speechText(in: package, at: 0, options: options))
        XCTAssertFalse(speech.contains("Preface"))
        XCTAssertFalse(speech.contains("Contents"))
        XCTAssertTrue(speech.contains("Visible speech text."))
    }

    func testDoubleEncodedAmpersandOffsetIsExact() throws {
        let chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Before &amp;lt; TARGET after</p></body></html>"
        let package = try makePackage(chapters: [chapter])

        let resultsTarget = EPUBParser().searchResults(for: "TARGET", in: package)
        XCTAssertEqual(resultsTarget.count, 1)
        XCTAssertEqual(resultsTarget.first?.characterOffset, 12)

        let resultsLt = EPUBParser().searchResults(for: "&lt;", in: package)
        XCTAssertEqual(resultsLt.count, 1)
        XCTAssertEqual(resultsLt.first?.characterOffset, 7)
    }

    func testSearchHonorsLimitAcrossChapters() throws {
        let chapter0 = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
                <p>MATCH one</p>
                <p>MATCH two</p>
            </body></html>
            """
        let chapter1 = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
                <p>MATCH three</p>
                <p>MATCH four</p>
            </body></html>
            """
        let package = try makePackage(chapters: [chapter0, chapter1])

        let results = EPUBParser().searchResults(for: "MATCH", in: package, limit: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].spineIndex, 0)
        XCTAssertEqual(results[1].spineIndex, 0)
        XCTAssertEqual(results[2].spineIndex, 1)
    }

    func testEmptyQueryReturnsNothing() throws {
        let chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Some searchable text</p></body></html>"
        let package = try makePackage(chapters: [chapter])

        XCTAssertTrue(EPUBParser().searchResults(for: "", in: package).isEmpty)
        XCTAssertTrue(EPUBParser().searchResults(for: "   \n\t  ", in: package).isEmpty)
    }
}
