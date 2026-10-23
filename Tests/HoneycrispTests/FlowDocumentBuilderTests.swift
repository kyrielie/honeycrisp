import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class FlowDocumentBuilderTests: XCTestCase {
    private var root: URL!
    private var ch1URL: URL!
    private var ch2URL: URL!
    private var spineLookup: [URL: Int]!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: "/tmp/fake-flow-book", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        ch1URL = root.appendingPathComponent("OEBPS/text/ch1.xhtml")
        ch2URL = root.appendingPathComponent("OEBPS/text/ch2.xhtml")
        spineLookup = [
            ch1URL.resolvingSymlinksInPath().standardizedFileURL: 0,
            ch2URL.resolvingSymlinksInPath().standardizedFileURL: 1,
        ]
    }

    func testElementIDsAreNamespacedPerResource() throws {
        let html = "<html><body><p id=\"intro\">Hello</p><a name=\"top\">Start</a></body></html>"
        let context = FlowDocumentBuilder.SectionContext(
            resource: 0,
            chapterURL: ch1URL,
            rootFolder: root,
            spineLookup: spineLookup,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml"
        )
        let rendered = try FlowDocumentBuilder.renderSectionHTML(
            html: html,
            context: context
        )

        let doc = try ChapterMarkup.parse(rendered, syntax: .html)
        let section = try doc.select("section.hc-chapter").first()!
        XCTAssertEqual(try section.attr("id"), "hc-r0")
        XCTAssertEqual(try section.attr("data-resource"), "0")

        let paragraph = try doc.select("p").first()!
        XCTAssertEqual(try paragraph.attr("id"), "hc-r0-intro")

        let a = try doc.select("a").first()!
        XCTAssertEqual(try a.attr("id"), "hc-r0-top")
    }

    func testSameChapterFragmentLinksAreRewritten() throws {
        let html = "<html><body><a href=\"#footnote-1\">Footnote</a><p id=\"footnote-1\">Reference</p></body></html>"
        let context = FlowDocumentBuilder.SectionContext(
            resource: 0,
            chapterURL: ch1URL,
            rootFolder: root,
            spineLookup: spineLookup,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml"
        )
        let rendered = try FlowDocumentBuilder.renderSectionHTML(
            html: html,
            context: context
        )

        let doc = try ChapterMarkup.parse(rendered, syntax: .html)
        let a = try doc.select("a").first()!
        XCTAssertEqual(try a.attr("href"), "#hc-r0-footnote-1")

        let paragraph = try doc.select("p").first()!
        XCTAssertEqual(try paragraph.attr("id"), "hc-r0-footnote-1")
    }

    func testCrossChapterLinksAreRewrittenToSectionOrElement() throws {
        let html = """
        <html><body>\
        <a id=\"l1\" href=\"ch2.xhtml#section-2\">Go Sec 2</a>\
        <a id=\"l2\" href=\"ch2.xhtml\">Go Ch 2</a>\
        <a id=\"l3\" href=\"https://example.com\">Web</a>\
        </body></html>
        """
        let context = FlowDocumentBuilder.SectionContext(
            resource: 0,
            chapterURL: ch1URL,
            rootFolder: root,
            spineLookup: spineLookup,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml"
        )
        let rendered = try FlowDocumentBuilder.renderSectionHTML(
            html: html,
            context: context
        )

        let doc = try ChapterMarkup.parse(rendered, syntax: .html)
        let l1 = try doc.select("#hc-r0-l1").first()!
        XCTAssertEqual(try l1.attr("href"), "#hc-r1-section-2")

        let l2 = try doc.select("#hc-r0-l2").first()!
        XCTAssertEqual(try l2.attr("href"), "#hc-r1")

        let l3 = try doc.select("#hc-r0-l3").first()!
        XCTAssertEqual(try l3.attr("href"), "https://example.com")
    }

    func testResourceURLsAreRewrittenToAppScheme() throws {
        let html = "<html><body><p><img src=\"../images/cover.jpg\"/></p></body></html>"
        let context = FlowDocumentBuilder.SectionContext(
            resource: 0,
            chapterURL: ch1URL,
            rootFolder: root,
            spineLookup: spineLookup,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml"
        )
        let rendered = try FlowDocumentBuilder.renderSectionHTML(
            html: html,
            context: context,
            urlScheme: "honeycrisp-epub"
        )

        let doc = try ChapterMarkup.parse(rendered, syntax: .html)
        let img = try doc.select("img").first()!
        XCTAssertEqual(try img.attr("src"), "honeycrisp-epub://book/OEBPS/images/cover.jpg")
    }

    func testActiveContentIsRemovedFromFlowSection() throws {
        let html = "<html><body><p onclick=\"alert('hack')\">Click</p><script>alert('run');</script></body></html>"
        let context = FlowDocumentBuilder.SectionContext(
            resource: 0,
            chapterURL: ch1URL,
            rootFolder: root,
            spineLookup: spineLookup,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml"
        )
        let rendered = try FlowDocumentBuilder.renderSectionHTML(
            html: html,
            context: context
        )

        XCTAssertFalse(rendered.contains("<script>"))
        XCTAssertFalse(rendered.contains("onclick"))
        XCTAssertTrue(rendered.contains("Click"))
    }

    func testWrapSectionsProducesValidDocumentStructure() {
        let section1 = "<section class=\"hc-chapter\" id=\"hc-r0\" data-resource=\"0\"><p>One</p></section>"
        let section2 = "<section class=\"hc-chapter\" id=\"hc-r1\" data-resource=\"1\"><p>Two</p></section>"
        let fullDoc = FlowDocumentBuilder.wrapSections(
            sections: [section1, section2],
            language: "en-US"
        )

        XCTAssertTrue(fullDoc.contains("<!doctype html>"))
        XCTAssertTrue(fullDoc.contains("<html lang=\"en-US\">"))
        XCTAssertTrue(fullDoc.contains("<style id=\"honeycrisp-vars\">"))
        XCTAssertTrue(fullDoc.contains(".hc-chapter"))
        XCTAssertTrue(fullDoc.contains("<div id=\"content\">"))
        XCTAssertTrue(fullDoc.contains("data-resource=\"0\""))
        XCTAssertTrue(fullDoc.contains("data-resource=\"1\""))
    }

    @MainActor
    func testBuildPagedDocumentContainsColumnCSSAndNoInlineScripts() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chURL = tempDir.appendingPathComponent("chapter1.xhtml")
        try "<html><body><h1>Title</h1><p>Body text</p></body></html>".write(to: chURL, atomically: true, encoding: .utf8)

        let manifest = ["chapter1.xhtml": EPUBManifestItem(id: "c1", href: "chapter1.xhtml", mediaType: "application/xhtml+xml", properties: [], url: chURL)]
        let spine = [EPUBSpineItem(manifestID: "c1", url: chURL, isLinear: true)]
        let pkg = EPUBPackage(
            rootFolder: tempDir,
            spineURLs: [chURL],
            title: "Test",
            author: "Author",
            coverURL: nil,
            manifest: manifest,
            spine: spine,
            language: "en"
        )

        let columnCSS = ":root { column-width: 300px; column-gap: 20px; }"
        let pagedHTML = try FlowDocumentBuilder.buildPagedDocument(
            resource: 0,
            package: pkg,
            columnCSS: columnCSS
        )

        XCTAssertTrue(pagedHTML.contains("column-width: 300px"))
        XCTAssertTrue(pagedHTML.contains("visibility: hidden;"))
        XCTAssertTrue(pagedHTML.contains("padding: 0 !important;"))
        XCTAssertTrue(pagedHTML.contains("data-resource=\"0\""))
        XCTAssertFalse(pagedHTML.contains("<script"))

        let surface = FlowSurface()
        surface.attachPaged(package: pkg, html: pagedHTML)
        XCTAssertEqual(surface.pagedDocumentURL?.absoluteString, "honeycrisp-epub://book/__app/paged.html")
        let servedData = surface.schemeHandler.appResources[FlowSurface.pagedResourcePath]
        XCTAssertNotNil(servedData)
        XCTAssertEqual(servedData, Data(pagedHTML.utf8))
    }
}
