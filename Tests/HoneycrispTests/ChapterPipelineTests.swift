import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class ChapterPipelineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testRenderRemovesActiveContentAndRewritesURLsAndHidesPreface() throws {
        let chapterURL = tempDirectory.appendingPathComponent("chapter1.xhtml")
        let source = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Test</title></head>
            <body>
              <script>alert('pwned');</script>
              <h2>Preface</h2>
              <p onclick="evil()">Hello world <img src="images/cover.jpg"/></p>
            </body>
            </html>
            """
        try Data(source.utf8).write(to: chapterURL)

        let rendered = try ChapterPipeline.render(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 0,
            root: tempDirectory,
            options: ChapterTransformOptions()
        )

        // Script and onclick must be removed
        XCTAssertFalse(rendered.contains("<script"))
        XCTAssertFalse(rendered.contains("onclick"))
        XCTAssertFalse(rendered.contains("pwned"))

        // Preface heading at resource 0 must be hidden (not deleted)
        XCTAssertTrue(rendered.contains("hidden"))
        XCTAssertTrue(rendered.contains("Preface"))

        // Image URL must be rewritten to absolute file: URL
        let expectedImageURL = tempDirectory.appendingPathComponent("images/cover.jpg").absoluteString
        XCTAssertTrue(rendered.contains(expectedImageURL))
    }

    func testOptionsFlowThroughToTransforms() throws {
        let chapterURL = tempDirectory.appendingPathComponent("chapter2.xhtml")
        let source = """
            <html xmlns="http://www.w3.org/1999/xhtml">
            <body>
              <h2 class="toc-heading">Table of Contents</h2>
              <b class="calibre2">Title</b>
              <p>&nbsp;</p>
              <p>Real text</p>
            </body>
            </html>
            """
        try Data(source.utf8).write(to: chapterURL)

        // With options disabled
        let renderedOff = try ChapterPipeline.render(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 1,
            root: tempDirectory,
            options: ChapterTransformOptions(formatAO3: false, markSpacers: false)
        )
        XCTAssertFalse(renderedOff.contains("hidden"))
        XCTAssertFalse(renderedOff.contains("ql-spacer"))

        // With options enabled
        let renderedOn = try ChapterPipeline.render(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 1,
            root: tempDirectory,
            options: ChapterTransformOptions(formatAO3: true, markSpacers: true)
        )
        XCTAssertTrue(renderedOn.contains("hidden"))
        XCTAssertTrue(renderedOn.contains("ql-spacer"))
    }

    func testMalformedXMLFallsBackToHTML() throws {
        let chapterURL = tempDirectory.appendingPathComponent("broken.xhtml")
        // Malformed XML: unclosed tags and unknown named entity &nbsp; without XHTML DTD
        let malformed = """
            <html xmlns="http://www.w3.org/1999/xhtml">
            <body>
              <p>First paragraph &nbsp;
              <p>Second paragraph
            </body>
            </html>
            """
        try Data(malformed.utf8).write(to: chapterURL)

        let rendered = try ChapterPipeline.render(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 1,
            root: tempDirectory,
            options: ChapterTransformOptions()
        )

        XCTAssertTrue(rendered.contains("First paragraph"))
        XCTAssertTrue(rendered.contains("Second paragraph"))

        let text = try ChapterPipeline.text(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 1,
            root: tempDirectory,
            options: ChapterTransformOptions()
        )
        XCTAssertTrue(text.string.contains("First paragraph"))
        XCTAssertTrue(text.string.contains("Second paragraph"))
    }

    func testUnparseableChapterReturnsEmptyBody() throws {
        let missingURL = tempDirectory.appendingPathComponent("nonexistent.xhtml")
        let rendered = try ChapterPipeline.render(
            chapterAt: missingURL,
            mediaType: "application/xhtml+xml",
            resource: 0,
            root: tempDirectory
        )
        XCTAssertEqual(rendered, "")

        let text = try ChapterPipeline.text(
            chapterAt: missingURL,
            mediaType: "application/xhtml+xml",
            resource: 0,
            root: tempDirectory
        )
        XCTAssertEqual(text.string, "")
        XCTAssertEqual(text.hiddenRanges, [])
    }

    func testLatin1ChapterWithXMLDeclarationDecodes() throws {
        let chapterURL = tempDirectory.appendingPathComponent("latin1.xhtml")
        let xmlDecl = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n"
        let content = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Caf\u{00E9} na\u{00EF}ve</p></body></html>"
        guard let data = (xmlDecl + content).data(using: .isoLatin1) else {
            XCTFail("Failed to encode fixture as ISO Latin 1")
            return
        }
        try data.write(to: chapterURL)

        let rendered = try ChapterPipeline.render(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 1,
            root: tempDirectory
        )
        XCTAssertTrue(rendered.contains("Café naïve"))

        let text = try ChapterPipeline.text(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 1,
            root: tempDirectory
        )
        XCTAssertTrue(text.string.contains("Café naïve"))
    }

    func testNoActiveContentInRenderedFixturesOrSyntheticBook() throws {
        try checkFixturesHaveNoActiveContent()
        try checkSyntheticBookHasNoActiveContent()
    }

    private func checkFixturesHaveNoActiveContent() throws {
        let allFixtures = ChapterFixtures.base + ChapterFixtures.transforms + ChapterFixtures.urls
        for fixture in allFixtures {
            let fileURL = tempDirectory.appendingPathComponent("ch_\(fixture.name).\(fixture.pathExtension)")
            try Data(fixture.source.utf8).write(to: fileURL)
            let rendered = try ChapterPipeline.render(
                chapterAt: fileURL,
                mediaType: fixture.mediaType,
                resource: 0,
                root: tempDirectory
            )
            assertNoActiveContent(in: rendered, sourceName: "fixture \(fixture.name)")
        }
    }

    private func checkSyntheticBookHasNoActiveContent() throws {
        let bookDir = tempDirectory.appendingPathComponent("BookActiveCheck", isDirectory: true)
        try SyntheticBook(pages: 60).write(to: bookDir)
        let package = try EPUBParser().parsePackage(at: bookDir)
        for url in package.spineURLs {
            let rendered = try ChapterPipeline.render(
                chapterAt: url,
                mediaType: "application/xhtml+xml",
                resource: 0,
                root: package.rootFolder
            )
            assertNoActiveContent(in: rendered, sourceName: "synthetic book chapter \(url.lastPathComponent)")
        }
    }

    private func assertNoActiveContent(in html: String, sourceName: String) {
        XCTAssertFalse(html.contains("<script"), "\(sourceName) must not contain <script")
        XCTAssertFalse(html.contains("javascript:"), "\(sourceName) must not contain javascript:")
        XCTAssertNil(
            html.range(of: #"on\w+\s*="#, options: .caseInsensitive),
            "\(sourceName) must not contain event handlers"
        )
    }
}
