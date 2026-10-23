import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class FlowLinkNavigationTests: XCTestCase {
    private var rootFolder: URL!
    private var ch0URL: URL!
    private var ch1URL: URL!
    private var spineLookup: [URL: Int]!

    override func setUp() {
        super.setUp()
        rootFolder = URL(fileURLWithPath: "/tmp/fake-flow-links", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        ch0URL = rootFolder.appendingPathComponent("OEBPS/text/ch0.xhtml")
        ch1URL = rootFolder.appendingPathComponent("OEBPS/text/ch1.xhtml")
        spineLookup = [
            ch0URL.resolvingSymlinksInPath().standardizedFileURL: 0,
            ch1URL.resolvingSymlinksInPath().standardizedFileURL: 1,
        ]
    }

    func testCrossChapterLinksAreRewrittenToTargetNamespaces() throws {
        let ch0HTML = """
            <html><body>
              <p id="ref1">Sentence with footnote <a href="ch1.xhtml#fn1">[1]</a>.</p>
            </body></html>
            """
        let ch1HTML = """
            <html><body>
              <p id="fn1">Footnote content. <a href="ch0.xhtml#ref1">Back</a></p>
            </body></html>
            """

        let ctx0 = FlowDocumentBuilder.SectionContext(
            resource: 0, chapterURL: ch0URL, rootFolder: rootFolder, spineLookup: spineLookup,
            mediaType: "application/xhtml+xml", pathExtension: "xhtml")
        let ctx1 = FlowDocumentBuilder.SectionContext(
            resource: 1, chapterURL: ch1URL, rootFolder: rootFolder, spineLookup: spineLookup,
            mediaType: "application/xhtml+xml", pathExtension: "xhtml")

        let rendered0 = try FlowDocumentBuilder.renderSectionHTML(html: ch0HTML, context: ctx0)
        let rendered1 = try FlowDocumentBuilder.renderSectionHTML(html: ch1HTML, context: ctx1)

        let doc0 = try ChapterMarkup.parse(rendered0, syntax: .html)
        let doc1 = try ChapterMarkup.parse(rendered1, syntax: .html)

        // Chapter 0 link points to Chapter 1's namespaced footnote
        let link0 = try doc0.select("a").first()
        XCTAssertEqual(try link0?.attr("href"), "#hc-r1-fn1")

        // Chapter 1 return link points to Chapter 0's namespaced reference
        let link1 = try doc1.select("a").first()
        XCTAssertEqual(try link1?.attr("href"), "#hc-r0-ref1")

        // Destination IDs are properly namespaced
        XCTAssertNotNil(try doc0.select("#hc-r0-ref1").first())
        XCTAssertNotNil(try doc1.select("#hc-r1-fn1").first())
    }

    func testNavigationActionLinkActivationPushesHistory() {
        var history = NavigationHistoryStack<NavigationLocation>()

        // Reader is reading chapter 0 at offset 120
        let readingLoc = NavigationLocation(resource: 0, offset: 120)

        // User clicks footnote link pointing to chapter 1
        history.push(readingLoc)
        let footnoteLoc = NavigationLocation(resource: 1, offset: 45)

        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        // User presses Back (⌘[) to return to reading location
        let returnLoc = history.goBack(current: footnoteLoc)
        XCTAssertEqual(returnLoc, readingLoc)
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        // User can also go forward again
        let reforwardLoc = history.goForward(current: readingLoc)
        XCTAssertEqual(reforwardLoc, footnoteLoc)
    }

    func testFlowSurfaceAllowsInBookFragmentNavigation() {
        let sameDocLink = URL(string: "honeycrisp-epub://book/__app/flow.html#hc-r1-fn1")
        let returnLink = URL(string: "honeycrisp-epub://book/__app/flow.html#hc-r0-ref1")
        let externalLink = URL(string: "https://example.com/source")

        XCTAssertTrue(FlowSurface.allowsNavigation(to: sameDocLink))
        XCTAssertTrue(FlowSurface.allowsNavigation(to: returnLink))
        XCTAssertFalse(FlowSurface.allowsNavigation(to: externalLink))
    }
}
