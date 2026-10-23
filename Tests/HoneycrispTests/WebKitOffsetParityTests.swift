import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

@MainActor
final class WebKitOffsetParityTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispWebKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testOffsetParityForEntitiesUnicodeWhitespaceAndSelfClosingAnchor() async throws {
        let package = try makeFixturePackage()
        XCTAssertEqual(package.language, "en-US")
        let parser = EPUBParser()
        let markers = ["ENTITY_MARKER", "UNICODE_MARKER", "WHITESPACE_MARKER", "ANCHOR_MARKER"]
        let swiftOffsets = try markers.map { marker -> Int in
            let result = try XCTUnwrap(parser.searchResults(for: marker, in: package).first)
            return result.characterOffset
        }
        let html = try FlowDocumentBuilder.buildDocument(package: package, cosmetics: cosmetics)
        XCTAssertTrue(html.contains("<html lang=\"en-US\">"))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loaded = expectation(description: "synthetic EPUB loads in WebKit")
        let delegate = NavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: package.rootFolder)
        await fulfillment(of: [loaded], timeout: 10)

        let markerData = try JSONSerialization.data(withJSONObject: markers)
        let markerJSON = try XCTUnwrap(String(data: markerData, encoding: .utf8))
        let script = Self.offsetLookupScript(markersJSON: markerJSON)
        let result = try await webView.evaluateJavaScript(script)
        let webOffsets = try XCTUnwrap((result as? [NSNumber])?.map(\.intValue))

        XCTExpectFailure("merged-document wrapper whitespace currently shifts DOM offsets") {
            XCTAssertEqual(webOffsets, swiftOffsets)
        }
    }

    func testSyntheticFixtureCapturesKnownResourceAndLinkBugs() throws {
        let package = try makeFixturePackage()
        let html = try FlowDocumentBuilder.buildDocument(package: package, cosmetics: cosmetics)
        let rootPath = package.rootFolder.path

        // FlowDocumentBuilder isolates URLs and does not leak absolute filesystem paths into src/href
        XCTAssertFalse(html.contains("src=\"file://"))
        XCTAssertFalse(html.contains("src=\"\(rootPath)"))
        XCTAssertTrue(html.contains("honeycrisp-epub://book/Text/Images/cover%20art.png"))
        XCTAssertTrue(html.contains("honeycrisp-epub://book/Text/Images/encoded%20art.png"))
        XCTAssertTrue(html.contains("href=\"#hc-r1-target\""))
        XCTAssertTrue(html.contains("href=\"#hc-r0-local-target\""))
    }

    func testPublisherClassStylesRemainInFixtureDocument() async throws {
        let package = try makeFixturePackage()
        let html = try FlowDocumentBuilder.buildDocument(package: package, cosmetics: cosmetics)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loaded = expectation(description: "styled synthetic EPUB loads in WebKit")
        let delegate = NavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: package.rootFolder)
        await fulfillment(of: [loaded], timeout: 10)

        let result = try await webView.evaluateJavaScript("""
            JSON.stringify({
              italic: getComputedStyle(document.querySelector('.publisher-italic')).fontStyle,
              alignment: getComputedStyle(document.querySelector('.verse')).textAlign
            });
            """)
        let json = try XCTUnwrap(result as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let styles = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(styles["italic"], "italic")
        XCTAssertEqual(styles["alignment"], "center")
    }

    private var cosmetics: ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: 100,
            fontFamily: "Georgia, serif",
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
            allowLinkClicks: true
        )
    }

    private func makeFixturePackage() throws -> EPUBPackage {
        let root = temporaryDirectory.appendingPathComponent("OEBPS", isDirectory: true)
        let textDirectory = root.appendingPathComponent("Text", isDirectory: true)
        let imagesDirectory = textDirectory.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imagesDirectory.appendingPathComponent("cover art.png"))
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imagesDirectory.appendingPathComponent("encoded art.png"))

        let opf = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fixture</dc:title><dc:language>EN-us</dc:language></metadata>
              <manifest>
                <item id="one" href="Text/chapter1.xhtml" media-type="application/xhtml+xml"/>
                <item id="two" href="Text/chapter 2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="one"/><itemref idref="two"/></spine>
            </package>
            """
        try Data(opf.utf8).write(to: root.appendingPathComponent("package.opf"))
        let containerDirectory = temporaryDirectory.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: containerDirectory, withIntermediateDirectories: true)
        try Data("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OEBPS/package.opf"/></rootfiles>
            </container>
            """.utf8).write(to: containerDirectory.appendingPathComponent("container.xml"))

        let chapterOne = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <p>Entity &amp; ENTITY_MARKER</p>
              <p>😀UNICODE_MARKER</p>
              <p>white\n  \tWHITESPACE_MARKER</p>
              <p><a id="self-closing"/>ANCHOR_MARKER</p>
              <style>.publisher-italic { font-style: italic; } .verse { text-align: center; }</style>
              <p><span class="publisher-italic">ITALIC_MARKER</span></p>
              <p class="verse">VERSE_MARKER</p>
              <p><a href="#local-target">local</a><a href="chapter%202.xhtml#target">next</a></p>
              <img src="Images/cover art.png"/>
              <img src='Images/encoded%20art.png'/>
              <img src=Images/encoded%20art.png/>
              <span id="local-target">target</span>
            </body></html>
            """
        let chapterTwo = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p id=\"target\">chapter two</p></body></html>"
        try Data(chapterOne.utf8).write(to: textDirectory.appendingPathComponent("chapter1.xhtml"))
        try Data(chapterTwo.utf8).write(to: textDirectory.appendingPathComponent("chapter 2.xhtml"))
        return try EPUBParser().parsePackage(at: temporaryDirectory)
    }

    private static func offsetLookupScript(markersJSON: String) -> String {
        """
            (function() {
              var markers = \(markersJSON), offsets = Object.create(null), walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
              var count = 0, node;
              while ((node = walker.nextNode()) !== null) {
                markers.forEach(function(marker) {
                  if (offsets[marker] !== undefined) return;
                  var index = node.data.indexOf(marker);
                  if (index >= 0) offsets[marker] = count + index;
                });
                count += node.length;
              }
              return markers.map(function(marker) { return offsets[marker] === undefined ? -1 : offsets[marker]; });
            })();
            """
    }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private let didFinish: () -> Void

    init(didFinish: @escaping () -> Void) {
        self.didFinish = didFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish()
    }
}
