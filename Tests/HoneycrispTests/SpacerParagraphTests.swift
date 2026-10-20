import Foundation
import XCTest
@testable import Honeycrisp

/// Spacer-paragraph collapsing: string-level checks on the built scroll HTML. Whether WebKit renders
/// the collapsed boxes at zero height needs a manual check on a synthetic fixture.
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

        XCTAssertTrue(html.contains("<p class=\"ql-spacer calibre7\">\(nbsp)</p>"))
        XCTAssertTrue(html.contains("<p class='ql-spacer calibre7'>&#160;</p>"))
        XCTAssertTrue(html.contains("<p class=\"ql-spacer\">&nbsp;</p>"))
        XCTAssertTrue(html.contains("<p class=\"ql-spacer\"> \n</p>"))
        XCTAssertTrue(html.contains("<p class=\"ql-spacer\"><br/></p>"))
        XCTAssertTrue(html.contains("<P class=\"ql-spacer\">&#xA0;</P>"))  // tag case preserved
        XCTAssertEqual(html.components(separatedBy: "class=\"ql-spacer").count - 1
                       + html.components(separatedBy: "class='ql-spacer").count - 1, 7)
    }

    func testRealParagraphsAndNonParagraphElementsAreNotTagged() throws {
        let html = try builtHTML(collapse: true)

        XCTAssertTrue(html.contains("<p class=\"calibre7\">Real text.\(nbsp)</p>"))
        XCTAssertTrue(html.contains("<p>&nbsp;x</p>"))
        XCTAssertTrue(html.contains("<pre>\(nbsp)</pre>"))
        XCTAssertTrue(html.contains("<p data-class=\"keep\">&nbsp;x</p>"))
    }

    func testDataClassAttributeIsNotMistakenForClass() throws {
        let html = try builtHTML(collapse: true)

        XCTAssertTrue(html.contains("<p data-class=\"keep\" class=\"ql-spacer\">&nbsp;</p>"))
    }

    func testSpacerTextNodesSurviveSoOffsetsAreUnchanged() throws {
        let off = try builtHTML(collapse: false)
        let on = try builtHTML(collapse: true)

        func visibleText(_ html: String) -> String {
            html.replacingOccurrences(of: " class=\"ql-spacer\"", with: "")
                .replacingOccurrences(of: "ql-spacer ", with: "")
                .replacingOccurrences(of: " class='ql-spacer'", with: "")
        }
        let bodyOff = off.components(separatedBy: "<section").dropFirst().joined()
        let bodyOn = on.components(separatedBy: "<section").dropFirst().joined()
        XCTAssertEqual(visibleText(bodyOn), bodyOff)
    }

    func testNothingIsTaggedByDefault() throws {
        let html = try builtHTML(collapse: false)

        XCTAssertFalse(html.contains("class=\"ql-spacer"))
        XCTAssertFalse(html.contains("class='ql-spacer"))
        XCTAssertTrue(html.contains("<p class=\"calibre7\">\(nbsp)</p>"))
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
        return try parser.buildScrollHTML(
            from: package, cosmetics: Self.cosmetics, collapseSpacerParagraphs: collapse
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
