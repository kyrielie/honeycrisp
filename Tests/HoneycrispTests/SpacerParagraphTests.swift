import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

/// Spacer-paragraph collapsing: checks on the built scroll HTML.
final class SpacerParagraphTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    private let nbsp = "\u{00a0}"

    func testSpacerParagraphsAreTaggedWhenEnabled() throws {
        let html = try builtHTML(collapse: true)
        let doc = try Parser.htmlParser().parseInput(html, "")
        let spacers = try doc.select("p.ql-spacer")
        XCTAssertEqual(spacers.size(), 7)

        let calibre7Spacers = try doc.select("p.calibre7.ql-spacer")
        XCTAssertEqual(calibre7Spacers.size(), 2)
        for spacer in calibre7Spacers {
            XCTAssertEqual(try spacer.attr("class"), "ql-spacer calibre7")
        }
    }

    func testRealParagraphsAndNonParagraphElementsAreNotTagged() throws {
        let html = try builtHTML(collapse: true)
        let doc = try Parser.htmlParser().parseInput(html, "")

        let realParagraphs = try doc.select("p:not(.ql-spacer)")
        XCTAssertEqual(realParagraphs.size(), 3)

        let pre = try doc.select("pre.ql-spacer")
        XCTAssertEqual(pre.size(), 0)

        let htmlDisabled = try builtHTML(collapse: false)
        let docDisabled = try Parser.htmlParser().parseInput(htmlDisabled, "")
        let zeroSpacers = try docDisabled.select("p.ql-spacer")
        XCTAssertEqual(zeroSpacers.size(), 0)
    }

    func testDataClassAttributeIsNotMistakenForClass() throws {
        let html = try builtHTML(collapse: true)
        let doc = try Parser.htmlParser().parseInput(html, "")
        let dataClassSpacer = try doc.select("p[data-class=keep].ql-spacer")
        XCTAssertEqual(dataClassSpacer.size(), 1)
    }

    func testSpacerTextNodesSurviveSoOffsetsAreUnchanged() throws {
        let off = try builtHTML(collapse: false)
        let on = try builtHTML(collapse: true)

        let docOff = try Parser.htmlParser().parseInput(off, "")
        let docOn = try Parser.htmlParser().parseInput(on, "")

        XCTAssertEqual(try docOff.body()?.text(), try docOn.body()?.text())
    }

    func testNothingIsTaggedByDefault() throws {
        let html = try builtHTML(collapse: false)
        let doc = try Parser.htmlParser().parseInput(html, "")
        let spacers = try doc.select(".ql-spacer")
        XCTAssertEqual(spacers.size(), 0)
    }

    // MARK: Fixture

    private static let chapter = """
        <html><body>
        <p class="calibre7">Real text.\u{00a0}</p><p class="calibre7">\u{00a0}</p>
        <p class='calibre7'>&#160;</p><p>&nbsp;</p><p> \n</p><p><br/></p><P>&#xA0;</P>
        <p>&nbsp;x</p><pre>\u{00a0}</pre><p data-class="keep">&nbsp;x</p><p data-class="keep">&nbsp;</p>
        </body></html>
        """

    private func builtHTML(collapse: Bool) throws -> String {
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
            <package><metadata><title>Spacers</title></metadata><manifest>
              <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="one"/></spine></package>
            """
        try Data(opf.utf8).write(to: root.appendingPathComponent("package.opf"))
        try Data(Self.chapter.utf8).write(to: root.appendingPathComponent("one.xhtml"))

        let parser = EPUBParser()
        let package = try parser.parsePackage(at: root)
        let options = ChapterTransformOptions(markSpacers: collapse)
        return try FlowDocumentBuilder.buildDocument(
            package: package, options: options, cosmetics: Self.cosmetics
        )
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
