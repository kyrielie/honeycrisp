import Foundation
import SwiftSoup
import XCTest
@testable import Honeycrisp

final class FlowTOCNavigationTests: XCTestCase {
    private var rootFolder: URL!
    private var ch0URL: URL!
    private var ch1URL: URL!
    private var spineLookup: [URL: Int]!

    override func setUp() {
        super.setUp()
        rootFolder = URL(fileURLWithPath: "/tmp/fake-flow-toc-book", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        ch0URL = rootFolder.appendingPathComponent("OEBPS/text/intro.xhtml")
        ch1URL = rootFolder.appendingPathComponent("OEBPS/text/chapter1.xhtml")
        spineLookup = [
            ch0URL.resolvingSymlinksInPath().standardizedFileURL: 0,
            ch1URL.resolvingSymlinksInPath().standardizedFileURL: 1,
        ]
    }

    func testFlowDocumentNamespacesIDsMatchingTOCFragments() throws {
        let ch0HTML = "<html><body><h1 id=\"title\">Intro</h1><p id=\"p1\">First paragraph</p></body></html>"
        let ch1HTML = "<html><body><h1 id=\"title\">Chapter 1</h1><div id=\"sec1\"><p>Details</p></div></body></html>"

        let ctx0 = FlowDocumentBuilder.SectionContext(
            resource: 0,
            chapterURL: ch0URL,
            rootFolder: rootFolder,
            spineLookup: spineLookup,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml"
        )
        let ctx1 = FlowDocumentBuilder.SectionContext(
            resource: 1,
            chapterURL: ch1URL,
            rootFolder: rootFolder,
            spineLookup: spineLookup,
            mediaType: "application/xhtml+xml",
            pathExtension: "xhtml"
        )

        let rendered0 = try FlowDocumentBuilder.renderSectionHTML(html: ch0HTML, context: ctx0)
        let rendered1 = try FlowDocumentBuilder.renderSectionHTML(html: ch1HTML, context: ctx1)

        let doc0 = try ChapterMarkup.parse(rendered0, syntax: .html)
        let doc1 = try ChapterMarkup.parse(rendered1, syntax: .html)

        // Chapter 0 elements namespaced as hc-r0-{id}
        XCTAssertNotNil(try doc0.select("#hc-r0-title").first())
        XCTAssertNotNil(try doc0.select("#hc-r0-p1").first())
        XCTAssertNil(try doc0.select("#title").first())

        // Chapter 1 elements namespaced as hc-r1-{id}
        XCTAssertNotNil(try doc1.select("#hc-r1-title").first())
        XCTAssertNotNil(try doc1.select("#hc-r1-sec1").first())
        XCTAssertNil(try doc1.select("#sec1").first())
    }

    func testReaderJSHasFallbackFragmentSelectors() {
        let js = EPUBParser.readerJS
        XCTAssertTrue(js.contains("window.navigateToFragment = function(id)"))
        XCTAssertTrue(js.contains("document.getElementById(id)"))
        XCTAssertTrue(js.contains("document.getElementsByName(id)"))
        XCTAssertTrue(js.contains("document.querySelector('[id$=\"-' + escaped + '\"]')"))
        XCTAssertTrue(js.contains("document.getElementById('hc-r' + id)"))
    }

    func testTOCEntryFragmentResolutionTarget() {
        var comp = URLComponents(url: ch1URL, resolvingAgainstBaseURL: false)!
        comp.fragment = "sec1"
        let entryURL = comp.url!
        let entryWithFragment = TOCEntry(
            title: "Section 1",
            href: "chapter1.xhtml#sec1",
            absoluteURL: entryURL,
            playOrder: 2
        )

        let targetURL = entryWithFragment.absoluteURL.standardizedFileURL
        let fragment = entryWithFragment.absoluteURL.fragment
            ?? URLComponents(url: targetURL, resolvingAgainstBaseURL: false)?.fragment

        XCTAssertEqual(fragment, "sec1")
        let namespacedTarget = "hc-r1-\(fragment ?? "")"
        XCTAssertEqual(namespacedTarget, "hc-r1-sec1")
    }

    func testTOCNavigationIntegratesWithHistoryStack() {
        var history = NavigationHistoryStack<NavigationLocation>()

        // User starts at cover / chapter 0 offset 0
        let initialLoc = NavigationLocation(resource: 0, offset: 0)

        // User clicks TOC entry for chapter 1 subsection
        history.push(initialLoc)
        let targetLoc = NavigationLocation(resource: 1, offset: 450)

        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        // Back navigates to chapter 0 offset 0
        let backLoc = history.goBack(current: targetLoc)
        XCTAssertEqual(backLoc, initialLoc)
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
    }

    func testStartReadingNodeWithFragmentResolvesToNamespacedID() {
        var comp = URLComponents(url: ch1URL, resolvingAgainstBaseURL: false)!
        comp.fragment = "intro"
        let landmarkURL = comp.url!
        let package = EPUBPackage(
            rootFolder: rootFolder,
            spineURLs: [ch0URL, ch1URL],
            title: "Book",
            author: "",
            coverURL: nil,
            landmarks: [EPUBLandmark(type: "bodymatter", title: "Story", url: landmarkURL)]
        )

        let parser = TOCParser()
        let startNode = parser.startReadingNode(in: package, toc: [])
        XCTAssertNotNil(startNode)
        XCTAssertEqual(startNode?.spineIndex, 1)

        let fragment = startNode?.url.fragment
            ?? URLComponents(url: startNode!.url, resolvingAgainstBaseURL: false)?.fragment
        XCTAssertEqual(fragment, "intro")

        let namespacedID = "hc-r\(startNode?.spineIndex ?? 0)-\(fragment ?? "")"
        XCTAssertEqual(namespacedID, "hc-r1-intro")
    }
}
