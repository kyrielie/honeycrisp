import Foundation
import XCTest
@testable import Honeycrisp

/// Phase 0a coverage: `ChapterRenderOptions` plumbing, active-content stripping, entity decoding and the
/// agreement between the text search indexes and the text a DOM walker would see.
///
/// Not covered here (no automated tests exist for them): `SettingsManager`, `ReaderViewController` and the
/// injected JS. A WKWebView `TreeWalker` length test was deliberately not added because it could not be run
/// where this change was written; see the Phase 0a notes.
final class ChapterBodyTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispChapterBodyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Options reach search and speech

    func testSearchOffsetsFollowRenderOptions() throws {
        let package = try makePackage(["<p>   Indented needle</p>"])
        let indentsOff = EPUBParser().searchResults(for: "needle", in: package, options: .plain)
        let indentsOn = EPUBParser().searchResults(
            for: "needle", in: package, options: ChapterRenderOptions(removeParagraphIndents: true)
        )
        XCTAssertEqual(indentsOff.first?.characterOffset, 12)
        XCTAssertEqual(indentsOn.first?.characterOffset, 9)
    }

    func testSpeechTextFollowsRenderOptions() throws {
        let package = try makePackage(["<p>   Indented text</p>"])
        let plain = EPUBParser().speechText(in: package, at: 0)
        let stripped = EPUBParser().speechText(in: package, at: 0, options: ChapterRenderOptions(removeParagraphIndents: true))
        XCTAssertEqual(plain, "   Indented text")
        XCTAssertEqual(stripped, "Indented text")
    }

    func testStyleTextIsNotCountedInSearchOffsets() throws {
        let package = try makePackage(["<p>Alpha</p><style>.x{color:red}</style><p>Beta needle</p>"])
        let results = EPUBParser().searchResults(for: "needle", in: package)
        XCTAssertEqual(results.first?.characterOffset, 10)
    }

    // MARK: - Offsets agree with an independent text collector

    func testSearchableTextMatchesStructuredCollectorWithIndentsRemoved() throws {
        let package = try makePackage([
            "<p>   Leading &amp; spaced&#160;text</p><p>Second &lt;b&gt; line</p><ul><li> item</li></ul>"
        ])
        let extracted = try EPUBParser.extractedChapterBody(
            from: package, index: 0, base: package.rootFolder,
            options: ChapterRenderOptions(removeParagraphIndents: true)
        )
        let collected = try XCTUnwrap(TextCollector.plainText(ofXHTMLFragment: extracted))
        XCTAssertEqual(EPUBParser.searchableText(fromHTML: extracted), collected)
        XCTAssertEqual(collected, "Leading & spaced\u{00A0}textSecond <b> lineitem")
    }

    // MARK: - Entity decoding

    func testDecodeHTMLEntitiesIsSinglePass() {
        XCTAssertEqual(EPUBParser.decodeHTMLEntities("&amp;lt;"), "&lt;")
        XCTAssertEqual(EPUBParser.decodeHTMLEntities("&amp;#65;"), "&#65;")
    }

    func testDecodeHTMLEntitiesHandlesTheSupportedSet() {
        XCTAssertEqual(EPUBParser.decodeHTMLEntities("&#39;&apos;&quot;&nbsp;&#x41;&#65;&AMP;"), "''\"\u{00A0}AA&")
        XCTAssertEqual(EPUBParser.decodeHTMLEntities("a&lt;b&gt;c"), "a<b>c")
    }

    func testDecodeHTMLEntitiesDropsInvalidScalarsAndKeepsUnknownNames() {
        XCTAssertEqual(EPUBParser.decodeHTMLEntities("x&#xD800;y"), "xy")
        XCTAssertEqual(EPUBParser.decodeHTMLEntities("&copy; &bogus;"), "&copy; &bogus;")
    }

    // MARK: - Active content

    func testStyleElementWithCDATAIsRemoved() {
        let html = "<p>A</p><style typeof=\"mw:Extension/templatestyles\" data-mw=\"x\"><![CDATA[.a{color:red}]]></style><p>B</p>"
        XCTAssertEqual(EPUBParser.stripActiveContent(html), "<p>A</p><p>B</p>")
    }

    func testScriptElementsAreRemoved() {
        XCTAssertEqual(EPUBParser.stripActiveContent("<p>A</p><script>alert(1)</script><p>B</p>"), "<p>A</p><p>B</p>")
        XCTAssertEqual(EPUBParser.stripActiveContent("<SCRIPT type=\"x\">\nalert(1)\n</SCRIPT><p>B</p>"), "<p>B</p>")
    }

    func testSelfClosingScriptDoesNotSwallowFollowingContent() {
        XCTAssertEqual(EPUBParser.stripActiveContent("<script src=\"x.js\"/><p>keep</p><script>a()</script>"), "<p>keep</p>")
    }

    func testUnclosedScriptTagIsRemoved() {
        XCTAssertEqual(EPUBParser.stripActiveContent("<p>keep</p><script src=\"x.js\">"), "<p>keep</p>")
    }

    func testEventHandlerAttributesAreRemoved() {
        XCTAssertEqual(
            EPUBParser.stripActiveContent("<a href=\"x.xhtml\" onclick=\"evil()\">t</a>"),
            "<a href=\"x.xhtml\">t</a>"
        )
        XCTAssertEqual(
            EPUBParser.stripActiveContent("<img src=\"a.png\" onload=\"x()\" onerror='y()'/>"),
            "<img src=\"a.png\"/>"
        )
        XCTAssertEqual(EPUBParser.stripActiveContent("<A HREF=\"x\" ONCLICK=\"y\">t</A>"), "<A HREF=\"x\">t</A>")
        XCTAssertEqual(EPUBParser.stripActiveContent("<img src=\"a.png\"/onerror=y()>"), "<img src=\"a.png\">")
    }

    func testHandlerLookalikesInValuesAndTextAreUntouched() {
        let quoted = "<p title=\"a onclick=1\">x</p>"
        let prose = "<p>I like onions = good</p>"
        XCTAssertEqual(EPUBParser.stripActiveContent(quoted), quoted)
        XCTAssertEqual(EPUBParser.stripActiveContent(prose), prose)
    }

    func testScriptSchemeURLsAreNeutralized() {
        XCTAssertEqual(EPUBParser.stripActiveContent("<a href=\"javascript:alert(1)\">x</a>"), "<a href=\"#\">x</a>")
        XCTAssertEqual(EPUBParser.stripActiveContent("<a href=\" JaVa&#x09;Script:alert(1)\">x</a>"), "<a href=\"#\">x</a>")
        XCTAssertEqual(EPUBParser.stripActiveContent("<a href='vbscript:x'>x</a>"), "<a href='#'>x</a>")
        XCTAssertEqual(EPUBParser.stripActiveContent("<iframe src=\"data:text/html,hi\"></iframe>"), "<iframe src=\"#\"></iframe>")
    }

    func testOrdinaryLinksAndImagesAreUntouched() {
        let html = "<a href=\"https://example.com/a?b=1&amp;c=2\">x</a><img src=\"data:image/png;base64,AAAA\"/>"
            + "<a href=\"ch2.xhtml#n1\">y</a><a href=\"mailto:a@example.com\">m</a>"
        XCTAssertEqual(EPUBParser.stripActiveContent(html), html)
    }

    func testExtractedChapterBodyStripsActiveContentEndToEnd() throws {
        let package = try makePackage([
            "<p onclick=\"x()\">Hello</p><script>evil()</script><a href=\"javascript:evil()\">link</a>"
        ])
        let extracted = try EPUBParser.extractedChapterBody(
            from: package, index: 0, base: package.rootFolder, options: .plain
        )
        XCTAssertEqual(extracted, "<p>Hello</p><a href=\"#\">link</a>")
    }

    // MARK: - Helpers

    private func makePackage(_ chapters: [String]) throws -> EPUBPackage {
        let root = try EPUBFixture.makeRoot(in: temporaryDirectory, chapters: chapters)
        return try EPUBParser().parsePackage(at: root)
    }
}

/// Test-only reference implementation of "the text a DOM text-node walk would see": parses an XHTML
/// fragment with `XMLParser` (which decodes entities and numeric references itself) and concatenates
/// character data outside `<style>` and `<script>`.
private final class TextCollector: NSObject, XMLParserDelegate {
    private var text = ""
    private var skipDepth = 0

    static func plainText(ofXHTMLFragment fragment: String) -> String? {
        let collector = TextCollector()
        let parser = XMLParser(data: Data("<root>\(fragment)</root>".utf8))
        parser.delegate = collector
        return parser.parse() ? collector.text : nil
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        if skipDepth > 0 || ["style", "script"].contains(elementName.lowercased()) { skipDepth += 1 }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 { skipDepth -= 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skipDepth == 0 { text += string }
    }
}
