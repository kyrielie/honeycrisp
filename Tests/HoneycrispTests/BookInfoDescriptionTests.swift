import Foundation
import XCTest
@testable import Honeycrisp

final class BookInfoDescriptionTests: XCTestCase {

    func testStripsHTMLTags() {
        let input = "<p>This is a <b>bold</b> and <i>italic</i> story.</p><br/><div>Second line</div>"
        let output = BookInfoViewController.cleanDescription(input)
        XCTAssertEqual(output, "This is a bold and italic story. Second line")
    }

    func testDecodesNamedHTMLEntities() {
        let input = "Tom &amp; Jerry &quot;Quotes&quot; &#39;Single&#39; &mdash; Dash &nbsp; Space"
        let output = BookInfoViewController.cleanDescription(input)
        XCTAssertEqual(output, "Tom & Jerry \"Quotes\" 'Single' — Dash Space")
    }

    func testDecodesNumericAndHexHTMLEntities() {
        // &#8212; is em-dash —, &#x2014; is em-dash —, &#65; is A
        let input = "Text &#8212; with decimal and &#x2014; hex and letter &#65;!"
        let output = BookInfoViewController.cleanDescription(input)
        XCTAssertEqual(output, "Text — with decimal and — hex and letter A!")
    }

    func testCollapsesExtraWhitespace() {
        let input = "  Lots   of \n\n extra \t  whitespace.   "
        let output = BookInfoViewController.cleanDescription(input)
        XCTAssertEqual(output, "Lots of extra whitespace.")
    }
}
