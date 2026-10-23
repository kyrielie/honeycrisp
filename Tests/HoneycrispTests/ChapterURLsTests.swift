import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class ChapterURLsTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: "/tmp/fake-book-root", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    func testNestedChapterImageResolvesFromChapterDirectory() throws {
        let chapterURL = root.appendingPathComponent("OEBPS/text/ch1.xhtml")
        let html = "<html><body><p><img src=\"../images/pic.png\"/></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let img = try body.select("img").first()!
        let expected = root.appendingPathComponent("OEBPS/images/pic.png").absoluteString
        XCTAssertEqual(try img.attr("src"), expected)
    }

    func testParentDirectoryReferenceStaysInsideRoot() throws {
        let chapterURL = root.appendingPathComponent("OEBPS/ch1.xhtml")
        let html = "<html><body><p><img src=\"../images/cover.jpg\"/></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let img = try body.select("img").first()!
        let expected = root.appendingPathComponent("images/cover.jpg").absoluteString
        XCTAssertEqual(try img.attr("src"), expected)
    }

    func testReferenceEscapingRootIsDropped() throws {
        let chapterURL = root.appendingPathComponent("OEBPS/ch1.xhtml")
        let html = "<html><body><p><img src=\"../../../../etc/passwd\"/></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let img = try body.select("img").first()!
        XCTAssertFalse(img.hasAttr("src"))
    }

    func testSingleQuotedAndPercentEncodedAttributesResolve() throws {
        let chapterURL = root.appendingPathComponent("ch1.xhtml")
        let html = "<html><body><p><img src='images/%20photo.png'/></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let img = try body.select("img").first()!
        let expected = root.appendingPathComponent("images").appendingPathComponent(" photo.png").absoluteString
        XCTAssertEqual(try img.attr("src"), expected)
    }

    func testCrossChapterHrefKeepsFragment() throws {
        let chapterURL = root.appendingPathComponent("OEBPS/ch1.xhtml")
        let html = "<html><body><p><a href=\"ch2.xhtml#section-1\">Next</a></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let link = try body.select("a").first()!
        let expected = root.appendingPathComponent("OEBPS/ch2.xhtml").absoluteString + "#section-1"
        XCTAssertEqual(try link.attr("href"), expected)
    }

    func testSchemeURLsAndFragmentOnlyLinksAreUntouched() throws {
        let chapterURL = root.appendingPathComponent("ch1.xhtml")
        let html = """
            <html><body>\
            <p><a href="https://example.com/page">Web</a></p>\
            <p><a href="mailto:a@b.com">Mail</a></p>\
            <p><a href="#footnote">Frag</a></p>\
            </body></html>
            """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let links = try body.select("a")
        XCTAssertEqual(try links.get(0).attr("href"), "https://example.com/page")
        XCTAssertEqual(try links.get(1).attr("href"), "mailto:a@b.com")
        XCTAssertEqual(try links.get(2).attr("href"), "#footnote")
    }

    func testRelativePathBeginningWithHttpIsRewritten() throws {
        let chapterURL = root.appendingPathComponent("ch1.xhtml")
        let html = "<html><body><p><a href=\"http-notes.xhtml\">Notes</a></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let link = try body.select("a").first()!
        let expected = root.appendingPathComponent("http-notes.xhtml").absoluteString
        XCTAssertEqual(try link.attr("href"), expected)
    }

    func testXlinkHrefIsRewritten() throws {
        let chapterURL = root.appendingPathComponent("ch1.xhtml")
        let html = "<html><body><svg><image xlink:href=\"images/pic.svg\"/></svg></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let image = try body.select("image").first()!
        let expected = root.appendingPathComponent("images/pic.svg").absoluteString
        XCTAssertEqual(try image.attr("xlink:href"), expected)
    }

    func testSpaceInFileNameIsPercentEncoded() throws {
        let chapterURL = root.appendingPathComponent("ch1.xhtml")
        let html = "<html><body><p><img src=\"images/my photo.png\"/></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)

        try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: root)

        let img = try body.select("img").first()!
        let expected = root.appendingPathComponent("images").appendingPathComponent("my photo.png").absoluteString
        XCTAssertEqual(try img.attr("src"), expected)
    }
}
