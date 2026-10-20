import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

/// SPIKE (roadmap M6, decision R5): can SwiftSoup replace the regex content pipeline without changing
/// text offsets? Compares SwiftSoup's DOM text with `EPUBParser.searchResults` offsets on synthetic
/// fixtures and records observations as kept attachments. Delete or promote per the R5 decision.
final class SwiftSoupSpikeTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispSoupSpike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try super.tearDownWithError()
    }

    private static let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title><style>.x { color: red; }</style></head><body>
        <p class="calibre7">ENTITY_MARKER &amp; caf&#233; &lt;tag&gt;</p>
        <p class="calibre7">&#160;</p>
        <p>UNICODE_MARKER \u{1F600} caf\u{00e9}</p>
        <p><br/></p>
        <p>Before <a id="x"/>ANCHOR_MARKER text</p>
        <script>var SCRIPT_MARKER = 1;</script>
        <p onclick="evil()">EVENT_MARKER <a href="javascript:alert(1)">JS_LINK_MARKER</a></p>
        <p>WHITESPACE_MARKER   two  spaces
        and a newline</p>
        <p>DOUBLE_MARKER &amp;lt; AFTER_DOUBLE_MARKER</p>
        </body></html>
        """

    private static let comparableMarkers = [
        "ENTITY_MARKER", "UNICODE_MARKER", "ANCHOR_MARKER", "EVENT_MARKER", "JS_LINK_MARKER", "WHITESPACE_MARKER",
        "DOUBLE_MARKER",
    ]

    // MARK: Serialization

    func testParsesXHTMLAndSerializesAsXML() throws {
        let document = try SwiftSoup.parse(Self.chapter, "", Parser.xmlParser())
        _ = document.outputSettings().syntax(syntax: .xml).prettyPrint(pretty: false)
        let output = try document.outerHtml()

        record("serialized prefix", String(output.prefix(160)))
        record("NBSP form", output.contains("\u{00a0}") ? "raw U+00A0" : "escaped or lost")
        XCTAssertTrue(output.contains("<a id=\"x\"/>"), "self-closing anchor must stay self-closing")
        XCTAssertTrue(output.contains("ANCHOR_MARKER"))
        XCTAssertTrue(output.contains("\u{00a0}") || output.contains("&#xa0;") || output.contains("&#160;"))
    }

    // MARK: Offsets

    func testTextNodeOffsetsMatchRegexPipelineForPlainMarkers() throws {
        let package = try makePackage(chapter: Self.chapter)
        let text = try domText(Self.chapter)

        for marker in Self.comparableMarkers where marker != "DOUBLE_MARKER" {
            let regexOffset = EPUBParser().searchResults(for: marker, in: package).first?.characterOffset
            let soupOffset = (text as NSString).range(of: marker).location
            XCTAssertEqual(soupOffset, regexOffset, "offset of \(marker)")
        }
    }

    func testRegexEntityDecodingDoubleDecodesAmpersandEntities() throws {
        let package = try makePackage(chapter: Self.chapter)
        let text = try domText(Self.chapter)
        let regexOffset = EPUBParser().searchResults(for: "AFTER_DOUBLE_MARKER", in: package).first?.characterOffset
        let soupOffset = (text as NSString).range(of: "AFTER_DOUBLE_MARKER").location

        record("AFTER_DOUBLE_MARKER offsets (SwiftSoup, regex)", "\(soupOffset), \(String(describing: regexOffset))")
        XCTExpectFailure("searchableText decodes &amp; before &lt;, so &amp;lt; becomes < and offsets drift") {
            XCTAssertEqual(soupOffset, regexOffset)
        }
    }

    func testActiveContentRemovalKeepsOffsetsOfSurvivingText() throws {
        let package = try makePackage(chapter: Self.chapter)
        let document = try SwiftSoup.parse(Self.chapter, "", Parser.xmlParser())
        _ = try document.select("script").remove()
        for element in try document.select("*").array() {
            for attribute in element.getAttributes()?.asList() ?? [] where attribute.getKey().lowercased().hasPrefix("on") {
                _ = try element.removeAttr(attribute.getKey())
            }
            let href = try element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if href.hasPrefix("javascript:") { _ = try element.removeAttr("href") }
        }
        _ = document.outputSettings().syntax(syntax: .xml).prettyPrint(pretty: false)
        let output = try document.outerHtml()

        XCTAssertFalse(output.contains("<script"))
        XCTAssertFalse(output.contains("onclick"))
        XCTAssertFalse(output.lowercased().contains("javascript:"))
        let cleaned = try domText(from: document)
        for marker in ["EVENT_MARKER", "JS_LINK_MARKER", "WHITESPACE_MARKER"] {
            let regexOffset = EPUBParser().searchResults(for: marker, in: package).first?.characterOffset
            XCTAssertEqual((cleaned as NSString).range(of: marker).location, regexOffset, "offset of \(marker) after removal")
        }
        XCTAssertFalse(cleaned.contains("SCRIPT_MARKER"))
    }

    // MARK: Spacer paragraphs

    func testSpacerDetectionMatchesRegexTagging() throws {
        let package = try makePackage(chapter: Self.chapter)
        let html = try EPUBParser().buildScrollHTML(
            from: package, cosmetics: Self.cosmetics, collapseSpacerParagraphs: true)
        let regexCount = html.components(separatedBy: "class=\"ql-spacer").count - 1

        let document = try SwiftSoup.parse(Self.chapter, "", Parser.xmlParser())
        let soupCount = try document.select("p").array().filter(Self.isSpacer).count

        XCTAssertEqual(soupCount, regexCount)
        XCTAssertEqual(soupCount, 2)
    }

    // MARK: Cost

    func testParseTimeOnAOneMegabyteChapterIsRecorded() throws {
        let paragraph = "<p class=\"calibre7\">Lorem ipsum dolor sit amet &amp; consectetur.</p><p class=\"calibre7\">&#160;</p>\n"
        let count = 1_000_000 / paragraph.utf8.count + 1
        let big = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>" + String(repeating: paragraph, count: count) + "</body></html>"

        let start = Date()
        let document = try SwiftSoup.parse(big, "", Parser.xmlParser())
        let seconds = Date().timeIntervalSince(start)
        let paragraphs = try document.select("p").array().count

        record("1 MB chapter parse", String(format: "%.2f s, %d paragraphs, %d bytes", seconds, paragraphs, big.utf8.count))
        XCTAssertEqual(paragraphs, count * 2)
        XCTAssertLessThan(seconds, 60, "sanity bound only; the recorded number is the result")
    }

    // MARK: Helpers

    private static func isSpacer(_ paragraph: Element) -> Bool {
        let children = paragraph.getChildNodes()
        guard !children.isEmpty else { return false }
        return children.allSatisfy { node in
            if let text = node as? TextNode {
                return text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let element = node as? Element { return element.tagName().lowercased() == "br" }
            return false
        }
    }

    private func domText(_ html: String) throws -> String {
        try domText(from: SwiftSoup.parse(html, "", Parser.xmlParser()))
    }

    private func domText(from document: Document) throws -> String {
        guard let body = try document.select("body").first() else { return "" }
        return Self.text(of: body)
    }

    /// Text-node text in DOM order, skipping script and style like `searchableText` does.
    private static func text(of node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        guard let element = node as? Element else { return "" }
        let name = element.tagName().lowercased()
        if name == "script" || name == "style" { return "" }
        return element.getChildNodes().map { text(of: $0) }.joined()
    }

    private func makePackage(chapter: String) throws -> EPUBPackage {
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        let container = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        try Data(container.utf8).write(to: metaInf.appendingPathComponent("container.xml"))
        let opf = """
            <package><metadata><title>Soup</title></metadata><manifest>
              <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="one"/></spine></package>
            """
        try Data(opf.utf8).write(to: root.appendingPathComponent("package.opf"))
        try Data(chapter.utf8).write(to: root.appendingPathComponent("one.xhtml"))
        return try EPUBParser().parsePackage(at: root)
    }

    private func record(_ name: String, _ value: Any?) {
        let attachment = XCTAttachment(string: "\(name): \(value.map { "\($0)" } ?? "nil")")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let cosmetics = ReaderCosmeticSettings(
        fontSizePercent: 100,
        fontFamily: "Charter, Georgia, serif",
        backgroundCSS: "#ffffff",
        textCSS: "#000000",
        linkCSS: "#0068da",
        hitBackground: "#ffee58",
        hitText: "#000000",
        hitActiveBackground: "#ffa000",
        hitActiveText: "#000000",
        lineHeight: 1.6,
        maxWidth: 700,
        paddingH: 24,
        allowLinkClicks: true,
        overrideMonospace: true,
        textAlignment: .book,
        hyphenate: false,
        language: nil,
        paragraphSpacing: 0,
        paragraphIndent: nil,
        boldWeight: .book
    )
}
