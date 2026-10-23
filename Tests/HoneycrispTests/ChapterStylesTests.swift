import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class ChapterStylesTests: XCTestCase {
    func testAllowedPropertyHarvesting() throws {
        let html = """
        <html>
        <head>
          <style>
            .italic-text { font-style: italic; }
            .oblique-text { font-style: oblique; }
            .bold-named { font-weight: bold; }
            .bold-numeric { font-weight: 700; }
            .underlined { text-decoration: underline; }
            .struck { text-decoration: line-through; }
            .both-decorations { text-decoration: underline line-through; }
            .centered { text-align: center; }
            .right-aligned { text-align: right; }
            .mono-text { font-family: "Courier New", monospace; }
            .hidden-text { display: none; }
          </style>
        </head>
        <body>
          <p class="italic-text">Italic</p>
          <p class="oblique-text">Oblique</p>
          <p class="bold-named">Bold Named</p>
          <p class="bold-numeric">Bold Numeric</p>
          <p class="underlined">Underlined</p>
          <p class="struck">Struck</p>
          <p class="both-decorations">Both</p>
          <p class="centered">Centered</p>
          <p class="right-aligned">Right</p>
          <p class="mono-text">Code</p>
          <p class="hidden-text">Hidden</p>
        </body>
        </html>
        """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: nil, rootFolder: nil)

        XCTAssertEqual(try body.select(".italic-text").attr("style"), "font-style: italic;")
        XCTAssertEqual(try body.select(".oblique-text").attr("style"), "font-style: oblique;")
        XCTAssertEqual(try body.select(".bold-named").attr("style"), "font-weight: bold;")
        XCTAssertEqual(try body.select(".bold-numeric").attr("style"), "font-weight: bold;")
        XCTAssertEqual(try body.select(".underlined").attr("style"), "text-decoration: underline;")
        XCTAssertEqual(try body.select(".struck").attr("style"), "text-decoration: line-through;")
        XCTAssertEqual(try body.select(".both-decorations").attr("style"), "text-decoration: underline line-through;")
        XCTAssertEqual(try body.select(".centered").attr("style"), "text-align: center;")
        XCTAssertEqual(try body.select(".right-aligned").attr("style"), "text-align: right;")
        XCTAssertEqual(try body.select(".mono-text").attr("style"), "font-family: monospace;")
        XCTAssertTrue(try body.select(".hidden-text").hasAttr("hidden"))
    }

    func testDiscardedGeometryAndColors() throws {
        let html = """
        <html>
        <head>
          <style>
            .geometry-and-color {
              color: #ff0000;
              background-color: #000000;
              margin: 40px 20px;
              padding: 10px;
              width: 500px;
              height: 200px;
              font-size: 24px;
              line-height: 2.5;
              text-align: justify;
              font-weight: 400;
              font-style: italic;
            }
          </style>
        </head>
        <body>
          <p class="geometry-and-color">Target text</p>
        </body>
        </html>
        """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: nil, rootFolder: nil)

        let target = try body.select(".geometry-and-color").first()!
        let style = try target.attr("style")
        XCTAssertEqual(style, "font-style: italic;")
        XCTAssertFalse(style.contains("color"))
        XCTAssertFalse(style.contains("background"))
        XCTAssertFalse(style.contains("margin"))
        XCTAssertFalse(style.contains("padding"))
        XCTAssertFalse(style.contains("width"))
        XCTAssertFalse(style.contains("height"))
        XCTAssertFalse(style.contains("font-size"))
        XCTAssertFalse(style.contains("line-height"))
        XCTAssertFalse(style.contains("justify"))
    }

    func testSimpleSelectorsAndCombinators() throws {
        let html = """
        <html>
        <head>
          <style>
            h1 { text-align: center; }
            #intro { font-weight: bold; }
            a.note { font-style: italic; }
            div#special { text-decoration: underline; }
            h2, h3 { text-align: right; }
            div > p { font-style: italic; }
            ul li { font-weight: bold; }
            p:hover { text-decoration: underline; }
          </style>
        </head>
        <body>
          <h1>Heading 1</h1>
          <p id="intro">Intro paragraph</p>
          <a class="note">Footnote</a>
          <div id="special">Special container</div>
          <h2>Heading 2</h2>
          <h3>Heading 3</h3>
          <div><p class="nested">Nested</p></div>
        </body>
        </html>
        """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: nil, rootFolder: nil)

        XCTAssertEqual(try body.select("h1").attr("style"), "text-align: center;")
        XCTAssertEqual(try body.select("#intro").attr("style"), "font-weight: bold;")
        XCTAssertEqual(try body.select("a.note").attr("style"), "font-style: italic;")
        XCTAssertEqual(try body.select("div#special").attr("style"), "text-decoration: underline;")
        XCTAssertEqual(try body.select("h2").attr("style"), "text-align: right;")
        XCTAssertEqual(try body.select("h3").attr("style"), "text-align: right;")
        XCTAssertFalse(try body.select(".nested").hasAttr("style"))
    }

    func testCascadeAndSourceOrder() throws {
        let html = """
        <html>
        <head>
          <style>
            .rule-a { text-align: center; font-style: italic; }
            .rule-b { text-align: right; }
          </style>
        </head>
        <body>
          <p class="rule-a rule-b">Cascade target</p>
          <p class="rule-a" style="font-style: normal; color: blue;">Inline override</p>
        </body>
        </html>
        """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: nil, rootFolder: nil)

        let target1 = try body.select(".rule-a.rule-b").first()!
        let style1 = try target1.attr("style")
        XCTAssertTrue(style1.contains("text-align: right;"))
        XCTAssertTrue(style1.contains("font-style: italic;"))

        let target2 = try body.select(".rule-a[style*=blue]").first()!
        let style2 = try target2.attr("style")
        XCTAssertTrue(style2.contains("font-style: normal;"))
        XCTAssertTrue(style2.contains("color: blue;"))
        XCTAssertTrue(style2.contains("text-align: center;"))
    }

    func testRuleN6SemanticElements() throws {
        let html = """
        <html>
        <body>
          <details><summary>Spoiler</summary><p>Secret text</p></details>
          <details open=""><summary>Already open</summary><p>Visible</p></details>
          <nav><a href="#ch1">Chapter 1</a></nav>
        </body>
        </html>
        """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: nil, rootFolder: nil)

        let detailsList = try body.select("details")
        for details in detailsList {
            XCTAssertTrue(details.hasAttr("open"))
        }

        let nav = try body.select("nav").first()!
        XCTAssertTrue(nav.hasAttr("hidden"))
    }

    func testStyleTagsRemovedFromBody() throws {
        let html = """
        <html>
        <body>
          <style>p { color: green; font-style: italic; }</style>
          <p>Paragraph</p>
        </body>
        </html>
        """
        let doc = try ChapterMarkup.parse(html, syntax: .html)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterStyles.apply(to: doc, body: body, chapterURL: nil, rootFolder: nil)

        XCTAssertEqual(try body.select("style").size(), 0)
        XCTAssertEqual(try body.select("p").attr("style"), "font-style: italic;")
    }
}
