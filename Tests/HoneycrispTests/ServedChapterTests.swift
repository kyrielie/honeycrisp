import Foundation
import XCTest
@testable import Honeycrisp

final class ServedChapterTests: XCTestCase {
    private let link = ServedChapter.readerStylesheetLink
    private let xhtmlNamespace = "xmlns=\"http://www.w3.org/1999/xhtml\""

    private func prepared(_ source: String, language: String? = nil, userCSS: String? = nil) -> String {
        String(decoding: ServedChapter.prepare(Data(source.utf8), language: language, userCSS: userCSS), as: UTF8.self)
    }

    func testLinkInsertedBeforeClosingHead() {
        let source = "<html><head><title>t</title><link href=\"a.css\"/></head><body><p>x</p></body></html>"
        let expected = source.replacingOccurrences(of: "</head>", with: link + "</head>")
        XCTAssertEqual(prepared(source), expected)
    }

    func testClosingHeadMatchedCaseInsensitively() {
        XCTAssertEqual(
            prepared("<HTML><HEAD></HEAD><BODY></BODY></HTML>"),
            "<HTML><HEAD>" + link + "</HEAD><BODY></BODY></HTML>")
    }

    func testHeadCreatedWhenMissing() {
        XCTAssertEqual(
            prepared("<html \(xhtmlNamespace)><body><p>x</p></body></html>"),
            "<html \(xhtmlNamespace)><head>" + link + "</head><body><p>x</p></body></html>")
    }

    func testSelfClosedHeadIsLeftAlone() {
        let source = "<html><head/><body></body></html>"
        XCTAssertEqual(prepared(source), source, "no second head is created next to a self-closed one")
    }

    func testDocumentWithoutHtmlElementIsUnchanged() {
        let source = "<p>fragment with &lt;html&gt; text</p>"
        XCTAssertEqual(prepared(source, language: "en"), source)
    }

    func testNonUTF8DataIsUnchanged() {
        let bytes = Data([0xFF, 0xFE, 0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E])
        XCTAssertEqual(ServedChapter.prepare(bytes, language: "en"), bytes)
    }

    func testLanguageAddedOnlyWhenRootHasNone() {
        let source = "<html \(xhtmlNamespace)><head></head><body></body></html>"
        XCTAssertEqual(
            prepared(source, language: "en-US"),
            "<html \(xhtmlNamespace) lang=\"en-US\"><head>" + link + "</head><body></body></html>")

        let withLang = "<html \(xhtmlNamespace) lang=\"fr\"><head></head><body></body></html>"
        let keptLang = prepared(withLang, language: "en")
        XCTAssertTrue(keptLang.contains("lang=\"fr\""))
        XCTAssertFalse(keptLang.contains("lang=\"en\""))

        let withXMLLang = "<html \(xhtmlNamespace) xml:lang=\"de\"><head></head><body></body></html>"
        XCTAssertFalse(prepared(withXMLLang, language: "en").contains("lang=\"en\""))
    }

    func testLanguageWithUnsafeCharactersIsIgnored() {
        let source = "<html \(xhtmlNamespace)><head></head><body></body></html>"
        let hostile = prepared(source, language: "en\"><script>alert(1)</script>")
        XCTAssertEqual(hostile, prepared(source, language: nil))
        XCTAssertFalse(hostile.contains("<script>"))
        XCTAssertEqual(prepared(source, language: ""), prepared(source, language: nil))
    }

    func testPrepareIsIdempotent() {
        let source = "<html \(xhtmlNamespace)><head><title>t</title></head><body><p>x</p></body></html>"
        let once = prepared(source, language: "en")
        XCTAssertEqual(prepared(once, language: "en"), once)
        XCTAssertEqual(once.components(separatedBy: link).count - 1, 1)
    }

    func testBodyBytesAreUnchanged() throws {
        let body = "<body>\n  <p>Entity &amp; text \u{1F600}</p>\r\n\t<a id=\"x\"/>after</body></html>"
        let source = "<html \(xhtmlNamespace)><head></head>" + body
        let output = prepared(source, language: "en")
        let start = try XCTUnwrap(output.range(of: "<body"))
        XCTAssertEqual(String(output[start.lowerBound...]), body, "text nodes, and so offsets, must not move")
    }

    func testXMLDeclarationAndDoctypeStayBeforeTheInsertedLink() throws {
        let doctype = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
        let source = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\(doctype)\n<html \(xhtmlNamespace)><head></head><body></body></html>"
        let output = prepared(source, language: "en")
        XCTAssertTrue(output.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>"))
        let doctypeRange = try XCTUnwrap(output.range(of: "<!DOCTYPE"))
        let linkRange = try XCTUnwrap(output.range(of: link))
        XCTAssertLessThan(doctypeRange.lowerBound, linkRange.lowerBound)
    }

    func testUserCSSIsInsertedAsStyleElementAfterTheLink() {
        let source = "<html><head><title>t</title></head><body><p>x</p></body></html>"
        let style = "<style id=\"honeycrisp-user\">/*<![CDATA[*/\n:root { --a: 1; }\n/*]]>*/</style>"
        XCTAssertEqual(
            prepared(source, userCSS: ":root { --a: 1; }"),
            "<html><head><title>t</title>" + link + style + "</head><body><p>x</p></body></html>")
    }

    func testUserCSSWithoutHeadCreatesHeadWithBothElements() {
        let output = prepared("<html><body></body></html>", userCSS: "p { color: red; }")
        XCTAssertTrue(output.hasPrefix("<html><head>" + link + "<style id=\"honeycrisp-user\">"))
        XCTAssertTrue(output.hasSuffix("</style></head><body></body></html>"))
    }

    func testUserCSSWithMarkupCharactersIsRefusedButTheLinkIsStillInserted() {
        for hostile in ["a {}</style><script>alert(1)</script>", "a {} ]]> <b>", "a { content: \"<\" }"] {
            let output = prepared("<html><head></head><body></body></html>", userCSS: hostile)
            XCTAssertEqual(output, "<html><head>" + link + "</head><body></body></html>", hostile)
        }
    }

    func testEmptyUserCSSInsertsNoStyleElement() {
        let output = prepared("<html><head></head><body></body></html>", userCSS: "")
        XCTAssertFalse(output.contains("honeycrisp-user"))
    }
}
