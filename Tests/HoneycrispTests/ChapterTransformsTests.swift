import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class ChapterTransformsTests: XCTestCase {
    func testTocHeadingIsHiddenNotDeletedAndTextStillCounted() throws {
        let html = """
            <html><body>\
            <h2 class="toc-heading">Table of Contents</h2>\
            <p>Chapter One</p>\
            </body></html>
            """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(formatAO3: true),
            hidePrefaceHeading: false,
            to: body
        )
        let renderedHTML = try ChapterMarkup.bodyHTML(of: body)

        XCTAssertTrue(renderedHTML.contains("hidden"))
        XCTAssertTrue(renderedHTML.contains("Table of Contents"))

        let text = try ChapterText.extract(fromServedBodyHTML: renderedHTML)
        XCTAssertTrue(text.string.contains("Table of Contents"))
        XCTAssertEqual(text.hiddenRanges.count, 1)

        let tocRange = (text.string as NSString).range(of: "Table of Contents")
        XCTAssertEqual(text.hiddenRanges.first, tocRange)
    }

    func testCalibre2StyleMergesWithExistingStyle() throws {
        let html = """
            <html><body>\
            <b class="calibre2">No style</b>\
            <b class="calibre2" style="color: red;">With semicolon</b>\
            <b class="calibre2" style="color: blue">Without semicolon</b>\
            <b class="calibre2" style="  ">Empty style</b>\
            </body></html>
            """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(formatAO3: true),
            hidePrefaceHeading: false,
            to: body
        )

        let boldTags = try body.select("b")
        let injection = "font-size:1.5em;font-weight:700;display:block;margin:0.5em 0;"

        XCTAssertEqual(try boldTags.get(0).attr("style"), injection)
        XCTAssertEqual(try boldTags.get(1).attr("style"), "color: red;" + injection)
        XCTAssertEqual(try boldTags.get(2).attr("style"), "color: blue;" + injection)
        XCTAssertEqual(try boldTags.get(3).attr("style"), injection)
    }

    func testTocHeadingTokenMatchIsExact() throws {
        let html = """
            <html><body>\
            <h2 class="xtoc-headingy">Not matched</h2>\
            <h2 class="first toc-heading last">Exact token</h2>\
            </body></html>
            """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(formatAO3: true),
            hidePrefaceHeading: false,
            to: body
        )

        let headings = try body.select("h2")
        XCTAssertFalse(headings.get(0).hasAttr("hidden"))
        XCTAssertTrue(headings.get(1).hasAttr("hidden"))
    }

    func testLeadingIndentWhitespaceIsLeftUntouched() throws {
        let html = """
            <html><body>\
            <p>   Indented paragraph</p>\
            <div>\tIndented div</div>\
            <li>  Indented list</li>\
            </body></html>
            """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(formatAO3: true, markSpacers: true),
            hidePrefaceHeading: true,
            to: body
        )
        let renderedHTML = try ChapterMarkup.bodyHTML(of: body)
        let text = try ChapterText.extract(fromServedBodyHTML: renderedHTML)

        XCTAssertTrue(renderedHTML.contains("   Indented paragraph"))
        XCTAssertTrue(renderedHTML.contains("\tIndented div"))
        XCTAssertTrue(renderedHTML.contains("  Indented list"))
        XCTAssertTrue(text.string.contains("   Indented paragraph"))
        XCTAssertTrue(text.string.contains("\tIndented div"))
        XCTAssertTrue(text.string.contains("  Indented list"))
    }

    func testSpacerVariantsAreTagged() throws {
        let html = """
            <html><body>\
            <p class="calibre7">\u{00a0}</p>\
            <p class="calibre7">&#160;</p>\
            <p>&nbsp;</p>\
            <p> \n</p>\
            <p><br/></p>\
            <p>&#xA0;</p>\
            <p data-class="keep">&nbsp;</p>\
            </body></html>
            """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(markSpacers: true),
            hidePrefaceHeading: false,
            to: body
        )

        let paragraphs = try body.select("p")
        XCTAssertEqual(paragraphs.size(), 7)
        for i in 0..<7 {
            let paragraph = paragraphs.get(i)
            XCTAssertTrue(try paragraph.classNames().contains("ql-spacer"), "Paragraph at index \(i) should be tagged")
        }

        XCTAssertEqual(try paragraphs.get(0).attr("class"), "ql-spacer calibre7")
        XCTAssertEqual(try paragraphs.get(1).attr("class"), "ql-spacer calibre7")
        XCTAssertEqual(try paragraphs.get(2).attr("class"), "ql-spacer")
        XCTAssertEqual(try paragraphs.get(3).attr("class"), "ql-spacer")
        XCTAssertEqual(try paragraphs.get(4).attr("class"), "ql-spacer")
        XCTAssertEqual(try paragraphs.get(5).attr("class"), "ql-spacer")
        XCTAssertEqual(try paragraphs.get(6).attr("class"), "ql-spacer")
    }

    func testRealParagraphsPreAndParamAreNotTagged() throws {
        let html = """
            <html><body>\
            <p class="calibre7">Real text.\u{00a0}</p>\
            <p>&nbsp;x</p>\
            <pre>\u{00a0}</pre>\
            <param name="foo" value="bar"/>\
            <p data-class="keep">&nbsp;x</p>\
            </body></html>
            """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(markSpacers: true),
            hidePrefaceHeading: false,
            to: body
        )

        let tagged = try body.select(".ql-spacer")
        XCTAssertEqual(tagged.size(), 0)
    }

    func testEmptyParagraphIsNotASpacer() throws {
        let html = "<html><body><p></p></body></html>"
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(markSpacers: true),
            hidePrefaceHeading: false,
            to: body
        )

        let tagged = try body.select(".ql-spacer")
        XCTAssertEqual(tagged.size(), 0)
    }

    func testPrefaceHeadingHiddenOnlyWhenRequestedAndOnlyExactText() throws {
        let html = """
            <html><body>\
            <h1>Preface</h1>\
            <h2>  preface  </h2>\
            <h3>Prefaces</h3>\
            <h4>Preface <i>x</i></h4>\
            <h5>PREFACE</h5>\
            <h6>preface</h6>\
            </body></html>
            """

        // When hidePrefaceHeading is false, nothing is hidden
        let docUnchanged = try ChapterMarkup.parse(html, syntax: .html)
        let bodyUnchanged = try ChapterMarkup.body(of: docUnchanged)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(),
            hidePrefaceHeading: false,
            to: bodyUnchanged
        )
        let hiddenUnchanged = try bodyUnchanged.select("[hidden]")
        XCTAssertEqual(hiddenUnchanged.size(), 0)

        // When hidePrefaceHeading is true, only exact match headings with no child elements are hidden
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(),
            hidePrefaceHeading: true,
            to: body
        )

        XCTAssertTrue(try body.select("h1").first()!.hasAttr("hidden"))
        XCTAssertTrue(try body.select("h2").first()!.hasAttr("hidden"))
        XCTAssertFalse(try body.select("h3").first()!.hasAttr("hidden"))
        XCTAssertFalse(try body.select("h4").first()!.hasAttr("hidden"))
        XCTAssertFalse(try body.select("h5").first()!.hasAttr("hidden"))
        XCTAssertTrue(try body.select("h6").first()!.hasAttr("hidden"))
    }
}
