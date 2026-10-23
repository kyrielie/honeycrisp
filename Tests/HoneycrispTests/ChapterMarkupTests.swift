import XCTest
import SwiftSoup
@testable import Honeycrisp

final class ChapterMarkupTests: XCTestCase {
    func testXHTMLIsParsedAsXMLAndHTMLAsHTML() throws {
        XCTAssertEqual(ChapterMarkup.syntax(mediaType: "application/xhtml+xml", pathExtension: "xhtml"), .xml)
        XCTAssertEqual(ChapterMarkup.syntax(mediaType: nil, pathExtension: "xhtml"), .xml)
        XCTAssertEqual(ChapterMarkup.syntax(mediaType: nil, pathExtension: "xml"), .xml)
        XCTAssertEqual(ChapterMarkup.syntax(mediaType: "text/html", pathExtension: "html"), .html)
        XCTAssertEqual(ChapterMarkup.syntax(mediaType: nil, pathExtension: "html"), .html)

        let xmlSource = "<div><p/><span>Text</span></div>"
        let xmlDoc = try ChapterMarkup.parse(xmlSource, syntax: .xml)
        let xmlBody = try ChapterMarkup.body(of: xmlDoc)
        let xmlHTML = try ChapterMarkup.bodyHTML(of: xmlBody)
        XCTAssertTrue(xmlHTML.contains("<p></p>"))

        let htmlSource = "<DIV><p>Hello</p></DIV>"
        let htmlDoc = try ChapterMarkup.parse(htmlSource, syntax: .html)
        let htmlBody = try ChapterMarkup.body(of: htmlDoc)
        let htmlHTML = try ChapterMarkup.bodyHTML(of: htmlBody)
        XCTAssertTrue(htmlHTML.contains("<p>Hello</p>"))
    }

    func testSelfClosingNonVoidElementsSerializeAsEmptyPairs() throws {
        let source = "<div><a id=\"x\"/>ANCHOR_MARKER <p/>NEXT_PARAGRAPH</div>"
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertTrue(html.contains("<a id=\"x\"></a>ANCHOR_MARKER"))
        XCTAssertTrue(html.contains("<p></p>NEXT_PARAGRAPH"))
    }

    func testScriptIframeObjectEmbedBaseAreRemoved() throws {
        let source = """
            <body>
              <p>Safe</p>
              <script>alert(1);</script>
              <iframe src="evil.html"></iframe>
              <object data="data.bin"></object>
              <embed src="movie.swf">
              <base href="https://evil.com">
            </body>
            """
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<iframe"))
        XCTAssertFalse(html.contains("<object"))
        XCTAssertFalse(html.contains("<embed"))
        XCTAssertFalse(html.contains("<base"))
        XCTAssertTrue(html.contains("<p>Safe</p>"))
    }

    func testRefreshMetaIsRemovedAndOtherMetaKept() throws {
        let source = """
            <body>
              <meta http-equiv="refresh" content="5;url=evil.html"/>
              <meta name="author" content="Test Author"/>
              <p>Content</p>
            </body>
            """
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertFalse(html.contains("http-equiv=\"refresh\""))
        XCTAssertTrue(html.contains("name=\"author\""))
    }

    func testEventHandlerAttributesAreRemovedIncludingMixedCase() throws {
        let source = """
            <body onload="init()">
              <p onClick="clickMe()" ONMOUSEOVER="hoverMe()">Click</p>
              <button onfocus="focusMe()">Btn</button>
            </body>
            """
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertFalse(html.lowercased().contains("onclick"))
        XCTAssertFalse(html.lowercased().contains("onmouseover"))
        XCTAssertFalse(html.lowercased().contains("onfocus"))
        XCTAssertTrue(html.contains("Click"))
    }

    func testJavaScriptURLsAreRemovedWithLeadingWhitespaceAndMixedCase() throws {
        let source = """
            <body>
              <a href=" JaVaScRiPt:alert(1)">Link 1</a>
              <img src="\r\n\t javascript:evil()"/>
              <form action="javascript:submitMe()"><button formaction="javascript:actionMe()">Go</button></form>
            </body>
            """
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertFalse(html.lowercased().contains("javascript:"))
        XCTAssertFalse(html.contains("href="))
        XCTAssertFalse(html.contains("src="))
        XCTAssertFalse(html.contains("action="))
        XCTAssertFalse(html.contains("formaction="))
    }

    func testOrdinaryLinksAndAttributesNamedOnlyLikeOnAreKept() throws {
        let source = """
            <body>
              <a href="chapter2.xhtml" data-once="value">Normal link</a>
            </body>
            """
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertTrue(html.contains("href=\"chapter2.xhtml\""))
        XCTAssertTrue(html.contains("data-once=\"value\""))
    }

    func testNoPrettyPrintWhitespaceIsAdded() throws {
        let source = "<body><span>One</span><span>Two</span></body>"
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertEqual(html, "<span>One</span><span>Two</span>")
    }

    func testBodylessFragmentUsesRoot() throws {
        let source = "<div><p>Fragment text</p></div>"
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        let html = try ChapterMarkup.bodyHTML(of: body)
        XCTAssertTrue(html.contains("<p>Fragment text</p>"))
    }
}
