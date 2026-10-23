import AppKit
import Foundation
import WebKit
import XCTest
@testable import Honeycrisp

@MainActor
final class ChapterPipelineParityTests: XCTestCase {
    private var webView: WKWebView!
    private var navigationDelegate: TestNavigationDelegate?

    override func setUp() async throws {
        try await super.setUp()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    override func tearDown() async throws {
        webView = nil
        navigationDelegate = nil
        try await super.tearDown()
    }

    func testBaseFixturesHaveTreeWalkerParityWithChapterText() async throws {
        for fixture in ChapterFixtures.base {
            let syntax = ChapterMarkup.syntax(mediaType: fixture.mediaType, pathExtension: fixture.pathExtension)
            let doc = try ChapterMarkup.parse(fixture.source, syntax: syntax)
            let body = try ChapterMarkup.body(of: doc)
            try ChapterMarkup.removeActiveContent(in: body)
            let html = try ChapterMarkup.bodyHTML(of: body)
            try await verifyParity(html: html, markers: fixture.markers, fixtureName: fixture.name)
        }
    }

    func testTransformFixturesKeepJSAndSwiftTextEqual() async throws {
        for fixture in ChapterFixtures.transforms {
            let syntax = ChapterMarkup.syntax(mediaType: fixture.mediaType, pathExtension: fixture.pathExtension)
            let doc = try ChapterMarkup.parse(fixture.source, syntax: syntax)
            let body = try ChapterMarkup.body(of: doc)
            try ChapterMarkup.removeActiveContent(in: body)
            try ChapterTransforms.apply(
                options: ChapterTransformOptions(formatAO3: true, markSpacers: true),
                hidePrefaceHeading: true,
                to: body
            )
            let html = try ChapterMarkup.bodyHTML(of: body)
            try await verifyParity(html: html, markers: fixture.markers, fixtureName: fixture.name)
        }
    }

    func testURLFixturesKeepJSAndSwiftTextEqual() async throws {
        for fixture in ChapterFixtures.urls {
            let syntax = ChapterMarkup.syntax(mediaType: fixture.mediaType, pathExtension: fixture.pathExtension)
            let doc = try ChapterMarkup.parse(fixture.source, syntax: syntax)
            let body = try ChapterMarkup.body(of: doc)
            try ChapterMarkup.removeActiveContent(in: body)
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let chapterURL = tempDir.appendingPathComponent("chapter1.xhtml")
            try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: tempDir)
            let html = try ChapterMarkup.bodyHTML(of: body)
            try await verifyParity(html: html, markers: fixture.markers, fixtureName: fixture.name)
        }
    }

    func testEveryFixtureSetPassesParity() async throws {
        for fixture in ChapterFixtures.base {
            try await verifyFixtureSetParity(fixture, category: "base")
        }
        for fixture in ChapterFixtures.transforms {
            try await verifyFixtureSetParity(fixture, category: "transforms")
        }
        for fixture in ChapterFixtures.urls {
            try await verifyFixtureSetParity(fixture, category: "urls")
        }
    }

    private func verifyFixtureSetParity(_ fixture: ChapterFixture, category: String) async throws {
        let syntax = ChapterMarkup.syntax(mediaType: fixture.mediaType, pathExtension: fixture.pathExtension)
        let doc = try ChapterMarkup.parse(fixture.source, syntax: syntax)
        let body = try ChapterMarkup.body(of: doc)
        try ChapterMarkup.removeActiveContent(in: body)
        if category == "transforms" {
            try ChapterTransforms.apply(
                options: ChapterTransformOptions(formatAO3: true, markSpacers: true),
                hidePrefaceHeading: true,
                to: body
            )
        } else if category == "urls" {
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let chapterURL = tempDir.appendingPathComponent("chapter1.xhtml")
            try ChapterURLs.rewrite(in: body, chapterURL: chapterURL, root: tempDir)
        }
        let html = try ChapterMarkup.bodyHTML(of: body)
        try await verifyParity(html: html, markers: fixture.markers, fixtureName: "\(category)/\(fixture.name)")
    }

    private func verifyParity(html: String, markers: [String], fixtureName: String) async throws {
        let fullHTML = "<!doctype html><html><body>\(html)</body></html>"
        try await loadHTML(fullHTML)

        let webTextResult = try await webView.evaluateJavaScript("""
            (function() {
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                var text = "";
                var node;
                while ((node = walker.nextNode()) !== null) {
                    text += node.data;
                }
                return text;
            })();
            """)
        let webText = (webTextResult as? String) ?? ""
        let chapterText = try ChapterText.extract(fromServedBodyHTML: html)

        XCTAssertEqual(webText, chapterText.string, "Text mismatch for fixture: \(fixtureName)")

        if !markers.isEmpty {
            let markersData = try JSONSerialization.data(withJSONObject: markers)
            let markersJSON = String(decoding: markersData, as: UTF8.self)
            let offsetsJSON = try await webView.evaluateJavaScript("""
                (function() {
                    var markers = \(markersJSON);
                    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                    var count = 0, node, offsets = {};
                    while ((node = walker.nextNode()) !== null) {
                        markers.forEach(function(m) {
                            if (offsets[m] !== undefined) return;
                            var idx = node.data.indexOf(m);
                            if (idx >= 0) { offsets[m] = count + idx; }
                        });
                        count += node.length;
                    }
                    return JSON.stringify(offsets);
                })();
                """) as? String ?? "{}"
            let webOffsets = try JSONSerialization.jsonObject(with: Data(offsetsJSON.utf8)) as? [String: Int] ?? [:]

            for marker in markers {
                let swiftOffset = (chapterText.string as NSString).range(of: marker).location
                let webOffset = webOffsets[marker] ?? -1
                XCTAssertEqual(webOffset, swiftOffset, "Marker \(marker) offset mismatch in fixture: \(fixtureName)")
            }
        }
    }

    func testHiddenElementsKeepOffsetsIdenticalToUnhiddenText() async throws {
        let source = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>\
            <h2 class="toc-heading">Table of Contents</h2>\
            <p>Body text MARKER</p>\
            </body></html>
            """
        let docUnhidden = try ChapterMarkup.parse(source, syntax: .xml)
        let bodyUnhidden = try ChapterMarkup.body(of: docUnhidden)
        let htmlUnhidden = try ChapterMarkup.bodyHTML(of: bodyUnhidden)
        let textUnhidden = try ChapterText.extract(fromServedBodyHTML: htmlUnhidden)

        let docHidden = try ChapterMarkup.parse(source, syntax: .xml)
        let bodyHidden = try ChapterMarkup.body(of: docHidden)
        try ChapterTransforms.apply(
            options: ChapterTransformOptions(formatAO3: true),
            hidePrefaceHeading: false,
            to: bodyHidden
        )
        let htmlHidden = try ChapterMarkup.bodyHTML(of: bodyHidden)
        let textHidden = try ChapterText.extract(fromServedBodyHTML: htmlHidden)

        XCTAssertEqual(textUnhidden.string, textHidden.string)

        let unhiddenOffset = (textUnhidden.string as NSString).range(of: "MARKER").location
        let hiddenOffset = (textHidden.string as NSString).range(of: "MARKER").location
        XCTAssertEqual(unhiddenOffset, hiddenOffset)

        let fullHTML = "<!doctype html><html><head><style>\(EPUBParser.readerCSS)</style></head><body>\(htmlHidden)</body></html>"
        try await loadHTML(fullHTML)

        let display = try await webView.evaluateJavaScript("""
            window.getComputedStyle(document.querySelector('[hidden]')).display;
            """) as? String
        XCTAssertEqual(display, "none")

        let webTextResult = try await webView.evaluateJavaScript("""
            (function() {
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                var text = "";
                var node;
                while ((node = walker.nextNode()) !== null) {
                    text += node.data;
                }
                return text;
            })();
            """) as? String ?? ""
        XCTAssertEqual(webTextResult, textHidden.string)
    }

    func testBuiltScrollDocumentSectionTextMatchesSwiftText() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try SyntheticBook(pages: 60).write(to: tempDir)

        let parser = EPUBParser()
        let package = try parser.parsePackage(at: tempDir)
        let scrollHTML = try parser.buildScrollHTML(from: package, cosmetics: Self.testCosmetics)
        try await loadHTML(scrollHTML)

        let script = """
            (function() {
                var sections = document.querySelectorAll('section.ql-chapter');
                var result = [];
                for (var i = 0; i < sections.length; i++) {
                    var walker = document.createTreeWalker(sections[i], NodeFilter.SHOW_TEXT, null);
                    var text = "";
                    var node;
                    while ((node = walker.nextNode()) !== null) { text += node.data; }
                    if (text.startsWith('\\n')) { text = text.substring(1); }
                    if (text.endsWith('\\n')) { text = text.substring(0, text.length - 1); }
                    result.push(text);
                }
                return JSON.stringify(result);
            })();
            """
        let sectionsJSON = try await webView.evaluateJavaScript(script) as? String ?? "[]"
        let webTexts = try JSONSerialization.jsonObject(with: Data(sectionsJSON.utf8)) as? [String] ?? []
        XCTAssertEqual(webTexts.count, package.spineURLs.count)

        for i in 0..<package.spineURLs.count {
            let mediaType = package.spine.indices.contains(i) ? package.manifest[package.spine[i].manifestID]?.mediaType : nil
            let swiftText = try ChapterPipeline.text(
                chapterAt: package.spineURLs[i],
                mediaType: mediaType,
                resource: i,
                root: package.rootFolder
            ).string
            XCTAssertEqual(webTexts[i], swiftText, "Section text mismatch for chapter index \(i)")
        }
    }

    func testSearchOffsetPlusMarkerEqualsWebKitWalkOffset() async throws {
        let targetNames = Set(["entities", "supplementary", "whitespace", "selfClosing"])
        let fixtures = ChapterFixtures.base.filter { targetNames.contains($0.name) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let parser = EPUBParser()
        for fixture in fixtures {
            try await verifySearchParity(for: fixture, in: tempDir, parser: parser)
        }
    }

    private func verifySearchParity(
        for fixture: ChapterFixture,
        in tempDir: URL,
        parser: EPUBParser
    ) async throws {
        let (package, fileURL) = try makeFixturePackage(for: fixture, in: tempDir)

        let bodyHTML = try ChapterPipeline.render(
            chapterAt: fileURL,
            mediaType: fixture.mediaType,
            resource: 0,
            root: tempDir
        )
        try await loadHTML("<!doctype html><html><body>\(bodyHTML)</body></html>")

        let markersData = try JSONSerialization.data(withJSONObject: fixture.markers)
        let markersJSON = String(decoding: markersData, as: UTF8.self)
        let offsetsScript = """
            (function() {
                var markers = \(markersJSON);
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                var count = 0, node, offsets = {};
                while ((node = walker.nextNode()) !== null) {
                    markers.forEach(function(m) {
                        if (offsets[m] !== undefined) return;
                        var idx = node.data.indexOf(m);
                        if (idx >= 0) { offsets[m] = count + idx; }
                    });
                    count += node.length;
                }
                return JSON.stringify(offsets);
            })();
            """
        let offsetsJSON = try await webView.evaluateJavaScript(offsetsScript) as? String ?? "{}"
        let webOffsets = try JSONSerialization.jsonObject(with: Data(offsetsJSON.utf8)) as? [String: Int] ?? [:]

        for marker in fixture.markers {
            let results = parser.searchResults(for: marker, in: package)
            let searchOffset = try XCTUnwrap(results.first?.characterOffset, "No search result for \(marker) in \(fixture.name)")
            let webOffset = try XCTUnwrap(webOffsets[marker], "No WebKit walk offset for \(marker) in \(fixture.name)")
            XCTAssertEqual(searchOffset, webOffset, "Search offset vs WebKit walk offset mismatch for marker '\(marker)' in \(fixture.name)")
        }
    }

    private func makeFixturePackage(
        for fixture: ChapterFixture,
        in tempDir: URL
    ) throws -> (EPUBPackage, URL) {
        let filename = "ch_\(fixture.name).\(fixture.pathExtension)"
        let fileURL = tempDir.appendingPathComponent(filename)
        try Data(fixture.source.utf8).write(to: fileURL)

        let manifestItem = EPUBManifestItem(
            id: fixture.name,
            href: filename,
            mediaType: fixture.mediaType ?? "application/xhtml+xml",
            properties: [],
            url: fileURL
        )
        let package = EPUBPackage(
            rootFolder: tempDir,
            spineURLs: [fileURL],
            title: fixture.name,
            author: "Test",
            coverURL: nil,
            manifest: [fixture.name: manifestItem],
            spine: [EPUBSpineItem(manifestID: fixture.name, url: fileURL, isLinear: true)]
        )
        return (package, fileURL)
    }

    private static let testCosmetics = ReaderCosmeticSettings(
        fontSizePercent: 100, fontFamily: "Charter, Georgia, serif", backgroundCSS: "#ffffff",
        textCSS: "#000000", linkCSS: "#0068da", hitBackground: "#ffee58", hitText: "#000000",
        hitActiveBackground: "#ffa000", hitActiveText: "#000000", lineHeight: 1.6, maxWidth: 700,
        paddingH: 24, allowLinkClicks: true, overrideMonospace: true, textAlignment: .book,
        hyphenate: false, language: nil, paragraphSpacing: 0, paragraphIndent: nil, boldWeight: .book
    )

    private func loadHTML(_ html: String) async throws {
        let loaded = expectation(description: "load html")
        let delegate = TestNavigationDelegate { loaded.fulfill() }
        self.navigationDelegate = delegate
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
    }
}

private final class TestNavigationDelegate: NSObject, WKNavigationDelegate {
    private let didFinish: () -> Void

    init(didFinish: @escaping () -> Void) {
        self.didFinish = didFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish()
    }
}
