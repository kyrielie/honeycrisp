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

    func testMissingTOCUsesSpineFilenamesAsFallback() {
        let package = makePackage(root: temporaryDirectory, spineNames: ["chapter_one.xhtml", "02-final.xhtml"])

        let entries = TOCParser().parseTOC(for: package)

        XCTAssertEqual(entries.map(\.title), ["Chapter One", "02-Final"])
        XCTAssertEqual(entries.map(\.playOrder), [1, 2])
        XCTAssertTrue(entries.allSatisfy { $0.children.isEmpty })
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
