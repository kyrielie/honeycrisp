import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class ChapterStylesIntegrationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterStylesIntegTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testExternalLinkedStylesheetHarvesting() throws {
        let cssURL = tempDirectory.appendingPathComponent("styles.css")
        let cssContent = """
        .chapter-title { text-align: center; font-weight: bold; }
        .hidden-marker { display: none; }
        """
        try Data(cssContent.utf8).write(to: cssURL)

        let chapterURL = tempDirectory.appendingPathComponent("chapter1.xhtml")
        let html = """
        <html>
        <head>
          <link rel="stylesheet" href="styles.css"/>
        </head>
        <body>
          <h1 class="chapter-title">Title</h1>
          <div class="hidden-marker">Hidden info</div>
        </body>
        </html>
        """
        try Data(html.utf8).write(to: chapterURL)

        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: chapterURL, rootFolder: tempDirectory)

        let title = try body.select(".chapter-title").first()!
        XCTAssertTrue(try title.attr("style").contains("text-align: center;"))
        XCTAssertTrue(try title.attr("style").contains("font-weight: bold;"))

        let hidden = try body.select(".hidden-marker").first()!
        XCTAssertTrue(hidden.hasAttr("hidden"))
    }

    func testSamplePatternsFicLabAndAO3() throws {
        let html = """
        <html>
        <head>
          <style>
            #landmarks { display: none; }
            .toc-heading { display: none; }
            .underline { text-decoration: underline; }
            .strikeout { text-decoration: line-through; }
            .monospace { font-family: monospace; }
            .align-center { text-align: center; }
            .align-right { text-align: right; }
          </style>
        </head>
        <body>
          <div id="landmarks"><ol><li>Cover</li></ol></div>
          <h2 class="toc-heading">Table of Contents</h2>
          <span class="underline">Underlined</span>
          <span class="strikeout">Struck</span>
          <span class="monospace">Code</span>
          <p class="align-center">Centered byline</p>
          <p class="align-right">Right verse</p>
        </body>
        </html>
        """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: nil, rootFolder: nil)

        XCTAssertTrue(try body.select("#landmarks").hasAttr("hidden"))
        XCTAssertTrue(try body.select(".toc-heading").hasAttr("hidden"))
        XCTAssertEqual(try body.select(".underline").attr("style"), "text-decoration: underline;")
        XCTAssertEqual(try body.select(".strikeout").attr("style"), "text-decoration: line-through;")
        XCTAssertEqual(try body.select(".monospace").attr("style"), "font-family: monospace;")
        XCTAssertEqual(try body.select(".align-center").attr("style"), "text-align: center;")
        XCTAssertEqual(try body.select(".align-right").attr("style"), "text-align: right;")
    }

    func testChapterPipelineIntegration() throws {
        let chapterURL = tempDirectory.appendingPathComponent("pipeline_ch.xhtml")
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <style>
            .verse { text-align: center; font-style: italic; }
            .secret { display: none; }
          </style>
        </head>
        <body>
          <p class="verse">A song in the dark</p>
          <p class="secret">Hidden secrets</p>
        </body>
        </html>
        """
        try Data(html.utf8).write(to: chapterURL)

        let rendered = try ChapterPipeline.render(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 0,
            root: tempDirectory
        )
        XCTAssertTrue(rendered.contains("text-align: center;"))
        XCTAssertTrue(rendered.contains("font-style: italic;"))
        XCTAssertTrue(rendered.contains("hidden"))

        let text = try ChapterPipeline.text(
            chapterAt: chapterURL,
            mediaType: "application/xhtml+xml",
            resource: 0,
            root: tempDirectory
        )
        XCTAssertTrue(text.string.contains("A song in the dark"))
        XCTAssertTrue(text.string.contains("Hidden secrets"))
        XCTAssertFalse(text.hiddenRanges.isEmpty)
    }

    func testFlowDocumentBuilderIntegration() throws {
        let ch1URL = tempDirectory.appendingPathComponent("ch1.xhtml")
        let html = """
        <html>
        <head>
          <style>
            .quote { font-style: italic; text-align: center; }
            .hidden-notes { display: none; }
          </style>
        </head>
        <body>
          <p id="q1" class="quote">Wise words</p>
          <div class="hidden-notes"><p>Footnote</p></div>
          <details><summary>More</summary><p>Expanded</p></details>
          <nav><p>Nav</p></nav>
        </body>
        </html>
        """
        let context = FlowDocumentBuilder.SectionContext(
            resource: 2,
            chapterURL: ch1URL,
            rootFolder: tempDirectory,
            spineLookup: [ch1URL: 2],
            mediaType: "text/html",
            pathExtension: "html"
        )
        let rendered = try FlowDocumentBuilder.renderSectionHTML(
            html: html,
            context: context
        )

        let doc = try ChapterMarkup.parse(rendered, syntax: .html)
        let quote = try doc.select("#hc-r2-q1").first()!
        XCTAssertTrue(try quote.attr("style").contains("font-style: italic;"))
        XCTAssertTrue(try quote.attr("style").contains("text-align: center;"))

        let notes = try doc.select(".hidden-notes").first()!
        XCTAssertTrue(notes.hasAttr("hidden"))

        let details = try doc.select("details").first()!
        XCTAssertTrue(details.hasAttr("open"))

        let nav = try doc.select("nav").first()!
        XCTAssertTrue(nav.hasAttr("hidden"))
    }
}
