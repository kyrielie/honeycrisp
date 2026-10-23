import XCTest
import SwiftSoup
@testable import Honeycrisp

final class ChapterTextTests: XCTestCase {
    func testAmpersandEntitiesDecodeOnce() throws {
        let html = "<p>&amp;lt;</p>"
        let text = try ChapterText.extract(fromServedBodyHTML: html)
        XCTAssertEqual(text.string, "&lt;")
    }

    func testSupplementaryCharacterCountsTwoUTF16Units() throws {
        let html = "<p>A\u{1F600}B</p>"
        let text = try ChapterText.extract(fromServedBodyHTML: html)
        XCTAssertEqual(text.string, "A\u{1F600}B")
        XCTAssertEqual((text.string as NSString).length, 4)
    }

    func testWhitespaceIsPreservedExactly() throws {
        let html = "<p>  two   spaces\tand\nnewline</p>"
        let text = try ChapterText.extract(fromServedBodyHTML: html)
        XCTAssertEqual(text.string, "  two   spaces\tand\nnewline")
    }

    func testStyleTextInBodyIsCounted() throws {
        let html = "<style>.c { color: blue; }</style><p>Hello</p>"
        let text = try ChapterText.extract(fromServedBodyHTML: html)
        XCTAssertTrue(text.string.contains(".c { color: blue; }"))
        XCTAssertTrue(text.string.contains("Hello"))
    }

    func testScriptTextIsAbsentAfterRemoval() throws {
        let source = "<body><script>var x = 1;</script><p>Surviving</p></body>"
        let doc = try ChapterMarkup.parse(source, syntax: .xml)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)
        let html = try ChapterMarkup.bodyHTML(of: body)
        let text = try ChapterText.extract(fromServedBodyHTML: html)
        XCTAssertFalse(text.string.contains("var x"))
        XCTAssertTrue(text.string.contains("Surviving"))
    }

    func testHiddenRangesCoverHiddenSubtreeOnly() throws {
        let html = "<p>Visible</p><div hidden><p>Hidden <span>subtree</span></p></div><p>Also visible</p>"
        let text = try ChapterText.extract(fromServedBodyHTML: html)
        XCTAssertEqual(text.hiddenRanges.count, 1)

        let hiddenRange = text.hiddenRanges[0]
        let hiddenSubstring = (text.string as NSString).substring(with: hiddenRange)
        XCTAssertEqual(hiddenSubstring, "Hidden subtree")
    }

    func testEmptyBodyGivesEmptyText() throws {
        let text = try ChapterText.extract(fromServedBodyHTML: "")
        XCTAssertEqual(text.string, "")
        XCTAssertTrue(text.hiddenRanges.isEmpty)
    }
}
