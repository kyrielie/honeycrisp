import Foundation

struct ChapterFixture {
    let name: String
    let source: String
    let mediaType: String?
    let pathExtension: String
    let markers: [String]
}

enum ChapterFixtures {
    static let base: [ChapterFixture] = [
        ChapterFixture(
            name: "entities",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Before &amp;lt; &#xA0; &copy; &#169; ENTITY_MARKER after</p></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["ENTITY_MARKER"],
        ),
        ChapterFixture(
            name: "supplementary",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Smile \u{1F600} SUPP_MARKER end</p></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["SUPP_MARKER"],
        ),
        ChapterFixture(
            name: "whitespace",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Tabs:\t\tand   runs\nand\r\nCRLF WS_MARKER done</p></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["WS_MARKER"],
        ),
        ChapterFixture(
            name: "selfClosing",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p/>Before <a id=\"x\"/>ANCHOR_MARKER text<br/>after</body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["ANCHOR_MARKER"],
        ),
        ChapterFixture(
            name: "preNewline",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><pre>\nline one\nline two PRE_MARKER</pre></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["PRE_MARKER"],
        ),
        ChapterFixture(
            name: "tableWhitespace",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><table>\n  <tr>\n    <td>TABLE_MARKER cell</td>\n  </tr>\n</table></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["TABLE_MARKER"],
        ),
        ChapterFixture(
            name: "scriptAndStyle",
            source: """
                <html xmlns="http://www.w3.org/1999/xhtml"><body><style>.x { color: red; }</style>\
                <p>PARAGRAPH_MARKER</p><script>var x = 1;</script></body></html>
                """,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["PARAGRAPH_MARKER"],
        ),
        ChapterFixture(
            name: "nestedParagraphs",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><div><p>OUTER_MARKER <span>INNER_MARKER</span></p></div></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["OUTER_MARKER", "INNER_MARKER"],
        ),
        ChapterFixture(
            name: "inlineSVG",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><svg><text>SVG_TEXT_MARKER</text></svg><p>AFTER_SVG_MARKER</p></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["SVG_TEXT_MARKER", "AFTER_SVG_MARKER"],
        ),
        ChapterFixture(
            name: "empty",
            source: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body></body></html>",
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: [],
        ),
    ]

    static let transforms: [ChapterFixture] = [
        ChapterFixture(
            name: "ao3Formatting",
            source: """
                <html xmlns="http://www.w3.org/1999/xhtml"><body>\
                <h2 class="toc-heading">Table of Contents</h2>\
                <p><b class="calibre2">Chapter One</b></p>\
                <p>AO3_MARKER text</p></body></html>
                """,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["AO3_MARKER"],
        ),
        ChapterFixture(
            name: "spacers",
            source: """
                <html xmlns="http://www.w3.org/1999/xhtml"><body>\
                <p class="calibre7">\u{00a0}</p>\
                <p>SPACER_MARKER text</p>\
                <p><br/></p>\
                <p>AFTER_SPACER_MARKER</p></body></html>
                """,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["SPACER_MARKER", "AFTER_SPACER_MARKER"],
        ),
        ChapterFixture(
            name: "preface",
            source: """
                <html xmlns="http://www.w3.org/1999/xhtml"><body>\
                <h2>Preface</h2>\
                <p>PREFACE_MARKER text</p></body></html>
                """,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["PREFACE_MARKER"],
        ),
    ]

    static let urls: [ChapterFixture] = [
        ChapterFixture(
            name: "urlsAndImages",
            source: """
                <html xmlns="http://www.w3.org/1999/xhtml"><body>\
                <p><a href="chapter2.xhtml#notes">Cross chapter LINK_MARKER</a></p>\
                <p><img src="images/fig1.png" alt="figure"/></p>\
                <p><a href="#local">Local link</a></p>\
                <p><a href="https://example.com">Web link</a></p>\
                </body></html>
                """,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml",
            markers: ["LINK_MARKER"],
        ),
    ]
}
