import Foundation
import XCTest
@testable import Honeycrisp

final class TOCParserTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispTOCTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testNCXParserPreservesHierarchyAndReadingOrder() throws {
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <navMap>
            <navPoint id="one"><navLabel><text>Part One</text></navLabel><content src="Text/one.xhtml"/>
              <navPoint id="one-a"><navLabel><text>Chapter One</text></navLabel><content src="Text/one.xhtml#a"/></navPoint>
            </navPoint>
            <navPoint id="two"><navLabel><text>Part Two</text></navLabel><content src="Text/two.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """
        try Data(ncx.utf8).write(to: temporaryDirectory.appendingPathComponent("toc.ncx"))
        let package = makePackage(root: temporaryDirectory, spineNames: ["one.xhtml", "two.xhtml"])

        let entries = TOCParser().parseTOC(for: package)

        XCTAssertEqual(entries.map(\.title), ["Part One", "Part Two"])
        XCTAssertEqual(entries.map(\.playOrder), [1, 3])
        XCTAssertEqual(entries[0].children.map(\.title), ["Chapter One"])
        XCTAssertEqual(entries[0].children.first?.playOrder, 2)
        XCTAssertEqual(entries[0].depth, 0)
        XCTAssertEqual(entries[0].children.first?.depth, 1)
    }

    func testEPUB3NavigationParserStripsNestedMarkupAndResolvesLinks() throws {
        let root = try XCTUnwrap(temporaryDirectory)
        let navDirectory = root.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: navDirectory, withIntermediateDirectories: true)
        let nav = """
        <html><body><nav epub:type="toc">
          <a href="Text/chapter.xhtml#start"><span>Chapter</span> One</a>
          <a href="#top">Skip this document-local link</a>
        </nav></body></html>
        """
        try Data(nav.utf8).write(to: navDirectory.appendingPathComponent("nav.xhtml"))
        let package = makePackage(root: root, spineNames: ["chapter.xhtml"])

        let entries = TOCParser().parseTOC(for: package)

        XCTAssertEqual(entries.map(\.title), ["Chapter One"])
        XCTAssertEqual(entries.first?.href, "Text/chapter.xhtml#start")
        XCTAssertTrue(entries.first?.absoluteURL.path.hasSuffix("/OEBPS/Text/chapter.xhtml") == true)
        XCTAssertEqual(entries.first?.absoluteURL.fragment, "start")
    }

    func testEPUB3NavigationPreservesNestedHierarchyAndManifestFragments() throws {
        let root = try XCTUnwrap(temporaryDirectory)
        let navURL = root.appendingPathComponent("navigation.xhtml")
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="Text/part.xhtml">Part I</a><ol>
              <li><a epub:type="toc" href="Text/chapter.xhtml#start"><span>Chapter</span> One</a></li>
            </ol></li>
          </ol></nav>
        </body></html>
        """
        try Data(nav.utf8).write(to: navURL)
        let rootFolder = root.appendingPathComponent("OEBPS", isDirectory: true)
        let partURL = rootFolder.appendingPathComponent("Text/part.xhtml")
        let chapterURL = rootFolder.appendingPathComponent("Text/chapter.xhtml")
        let package = EPUBPackage(
            rootFolder: rootFolder,
            spineURLs: [partURL, chapterURL],
            title: "Nested",
            author: "",
            coverURL: nil,
            navigationURL: navURL
        )

        let entries = TOCParser().parseTOC(for: package)

        XCTAssertEqual(entries.map(\.title), ["Part I"])
        XCTAssertEqual(entries.first?.children.map(\.title), ["Chapter One"])
        XCTAssertEqual(entries.first?.children.first?.absoluteURL.fragment, "start")
    }

    func testStartReadingUsesBodymatterLandmarkThenConservativeFrontMatterFallback() {
        let chapterOne = temporaryDirectory.appendingPathComponent("title-page.xhtml")
        let chapterTwo = temporaryDirectory.appendingPathComponent("chapter-1.xhtml")
        let spine = [
            EPUBSpineItem(manifestID: "title", url: chapterOne, isLinear: true),
            EPUBSpineItem(manifestID: "chapter", url: chapterTwo, isLinear: true),
        ]
        let noLandmark = EPUBPackage(
            rootFolder: temporaryDirectory, spineURLs: [chapterOne, chapterTwo], title: "Book", author: "",
            coverURL: nil, spine: spine)

        XCTAssertEqual(TOCParser().startReadingNode(in: noLandmark, toc: [])?.spineIndex, 1)

        let withLandmark = EPUBPackage(
            rootFolder: temporaryDirectory,
            spineURLs: [chapterOne, chapterTwo],
            title: "Book",
            author: "",
            coverURL: nil,
            spine: spine,
            landmarks: [EPUBLandmark(type: "bodymatter", title: "Story", url: chapterTwo)]
        )
        XCTAssertEqual(TOCParser().startReadingNode(in: withLandmark, toc: [])?.spineIndex, 1)
        XCTAssertTrue(TOCParser().startReadingNode(in: withLandmark, toc: [])?.isLandmark == true)
    }

    func testMissingTOCUsesSpineFilenamesAsFallback() {
        let package = makePackage(root: temporaryDirectory, spineNames: ["chapter_one.xhtml", "02-final.xhtml"])

        let entries = TOCParser().parseTOC(for: package)

        XCTAssertEqual(entries.map(\.title), ["Chapter One", "02-Final"])
        XCTAssertEqual(entries.map(\.playOrder), [1, 2])
        XCTAssertTrue(entries.allSatisfy { $0.children.isEmpty })
    }

    func testSynthesizedTitleKeepsPrefixAndNumberForGenericFilenames() {
        XCTAssertEqual(TOCParser.fallbackTitle(forFileNamed: "Part0001", spineIndex: 0), "Part 1")
        XCTAssertEqual(TOCParser.fallbackTitle(forFileNamed: "chapter_12", spineIndex: 11), "Chapter 12")
        XCTAssertEqual(TOCParser.fallbackTitle(forFileNamed: "Section-03", spineIndex: 2), "Section 3")
    }

    func testSynthesizedTitleForDigitOnlyFilenameUsesSpinePosition() {
        XCTAssertEqual(TOCParser.fallbackTitle(forFileNamed: "0007", spineIndex: 2), "Section 3")
        XCTAssertEqual(TOCParser.fallbackTitle(forFileNamed: "123", spineIndex: 0), "Section 1")
    }

    func testHTML5NavThatIsNotXMLKeepsNestedHierarchy() throws {
        let navURL = temporaryDirectory.appendingPathComponent("nav.xhtml")
        // HTML5 with unclosed <br>, HTML entity &nbsp; that would break XMLDocument
        let navHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <nav epub:type="toc">
            <h2>Contents</h2><br>
            <ol>
              <li>
                <a href="Text/part1.xhtml">Part&nbsp;One</a>
                <ol>
                  <li><a href="Text/c1.xhtml">Chapter 1</a></li>
                </ol>
              </li>
            </ol>
          </nav>
        </body>
        </html>
        """
        try Data(navHTML.utf8).write(to: navURL)
        let package = EPUBPackage(
            rootFolder: temporaryDirectory,
            spineURLs: [temporaryDirectory.appendingPathComponent("Text/part1.xhtml"), temporaryDirectory.appendingPathComponent("Text/c1.xhtml")],
            title: "HTML5 Nav",
            author: "",
            coverURL: nil,
            navigationURL: navURL
        )

        let entries = TOCParser().parseTOC(for: package)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Part One")
        XCTAssertEqual(entries[0].depth, 0)
        XCTAssertEqual(entries[0].playOrder, 1)

        XCTAssertEqual(entries[0].children.count, 1)
        XCTAssertEqual(entries[0].children[0].title, "Chapter 1")
        XCTAssertEqual(entries[0].children[0].depth, 1)
        XCTAssertEqual(entries[0].children[0].playOrder, 2)
    }

    func testHTML5NavFallbackIgnoresLandmarksAndPageList() throws {
        let navURL = temporaryDirectory.appendingPathComponent("nav.xhtml")
        let navHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <nav epub:type="landmarks">
            <ol><li><a href="Text/cover.xhtml">Cover</a></li></ol>
          </nav>
          <nav epub:type="toc">
            <ol><li><a href="Text/chapter1.xhtml">Chapter 1</a></li></ol>
          </nav>
        </body>
        </html>
        """
        try Data(navHTML.utf8).write(to: navURL)
        let package = EPUBPackage(
            rootFolder: temporaryDirectory,
            spineURLs: [temporaryDirectory.appendingPathComponent("Text/chapter1.xhtml")],
            title: "TOC",
            author: "",
            coverURL: nil,
            navigationURL: navURL
        )

        let entries = TOCParser().parseTOC(for: package)
        XCTAssertEqual(entries.map(\.title), ["Chapter 1"])
    }

    func testLandmarksOnlyNavIsNotUsedAsTOCAndNCXWins() throws {
        let navURL = temporaryDirectory.appendingPathComponent("nav.xhtml")
        let navXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body>
          <nav epub:type="landmarks">
            <ol><li><a href="Text/cover.xhtml">Cover</a></li></ol>
          </nav>
        </body>
        </html>
        """
        try Data(navXML.utf8).write(to: navURL)

        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <navMap>
            <navPoint id="c1"><navLabel><text>NCX Chapter 1</text></navLabel><content src="Text/c1.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """
        try Data(ncx.utf8).write(to: temporaryDirectory.appendingPathComponent("toc.ncx"))

        let package = EPUBPackage(
            rootFolder: temporaryDirectory,
            spineURLs: [temporaryDirectory.appendingPathComponent("Text/c1.xhtml")],
            title: "Book",
            author: "",
            coverURL: nil
            // Note: navigationURL omitted so findNav and findNCX are checked
        )

        let entries = TOCParser().parseTOC(for: package)
        XCTAssertEqual(entries.map(\.title), ["NCX Chapter 1"])
    }

    func testFindNavDoesNotMatchUnrelatedFilenames() throws {
        let textDir = temporaryDirectory.appendingPathComponent("Text", isDirectory: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)

        let canvas = "<html><body><canvas>Canvas content</canvas></body></html>"
        try Data(canvas.utf8).write(to: temporaryDirectory.appendingPathComponent("canvas.xhtml"))

        let naval = "<html><body><p>Naval History</p></body></html>"
        try Data(naval.utf8).write(to: textDir.appendingPathComponent("naval.xhtml"))

        let package = makePackage(root: temporaryDirectory, spineNames: ["chapter_one.xhtml"])

        let entries = TOCParser().parseTOC(for: package)
        // Since canvas.xhtml and naval.xhtml are not valid nav documents and no NCX exists, synthesiseFromSpine wins
        XCTAssertEqual(entries.map(\.title), ["Chapter One"])
    }

    func testFindNavAcceptsNavXhtmlNotDeclaredInTheManifest() throws {
        let navHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <nav epub:type="toc">
            <ol><li><a href="Text/c1.xhtml">Undeclared Nav Chapter</a></li></ol>
          </nav>
        </body>
        </html>
        """
        try Data(navHTML.utf8).write(to: temporaryDirectory.appendingPathComponent("nav.xhtml"))

        let package = makePackage(root: temporaryDirectory, spineNames: ["c1.xhtml"])
        let entries = TOCParser().parseTOC(for: package)
        XCTAssertEqual(entries.map(\.title), ["Undeclared Nav Chapter"])
    }

    private func makePackage(root: URL, spineNames: [String]) -> EPUBPackage {
        return EPUBPackage(
            rootFolder: root,
            spineURLs: spineNames.map { root.appendingPathComponent("Text/\($0)") },
            title: "TOC Test",
            author: "",
            coverURL: nil
        )
    }
}
