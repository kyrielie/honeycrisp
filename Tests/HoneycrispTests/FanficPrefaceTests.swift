import Foundation
import XCTest
@testable import Honeycrisp

final class FanficPrefaceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispFanficTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try super.tearDownWithError()
    }

    func testNativeAO3DetectionAndSpineRoles() throws {
        let package = try makePackage([
            #"<div id="preface"><p class="message">Posted originally on the Archive of Our Own at https://archiveofourown.org/works/1</p><dl class="tags"><dt>Rating:</dt><dd>General Audiences</dd></dl></div>"#,
            #"<div id="preface"><h1>Fixture Title</h1><div class="byline"><a rel="author" href="https://archiveofourown.org/users/test">Fixture Author</a></div><blockquote class="userstuff"><p>Summary &amp; details.</p></blockquote></div><div id="chapters"><div></div></div>"#,
            #"<div id="chapters"><h2>Chapter One</h2><div><p>Story.</p></div></div><div id="afterword"><div></div></div>"#,
            #"<div id="afterword"><h2>Afterword</h2><p>Thanks.</p></div>"#
        ], metadata: ["publisher": ["Archive of Our Own"], "title": ["Fixture Title"]])

        XCTAssertEqual(BookIdentity.detect(package).generator, .ao3Native)
        XCTAssertEqual(FrontMatterPlan.detect(in: package)?.roles, [.primaryPreface, .cut, .chapter, .backMatter])
        let meta = try XCTUnwrap(WorkMetaExtractor.extract(from: package))
        XCTAssertEqual(meta.title, "Fixture Title")
        XCTAssertEqual(meta.authors.first?.name, "Fixture Author")
        XCTAssertEqual(meta.summaryHTML, "<p>Summary &amp; details.</p>")
    }

    func testFicHubRequiresCreditAndExtractsAuthor() throws {
        let undetected = try makePackage(["<p>By: Fixture Author</p>", "<nav>Contents</nav>"])
        XCTAssertEqual(BookIdentity.detect(undetected).generator, .unknown)

        let package = try makePackage([
            "<h1>Fixture Title</h1><p><b>By: Fixture Author</b></p><p>Summary text</p><p>Status: Complete</p><p>Exported with the assistance of FicHub.net</p>",
            "<nav epub:type='toc'>Contents</nav>"
        ], metadata: ["title": ["Fixture Title"]])
        XCTAssertEqual(BookIdentity.detect(package).generator, .fichub)
        XCTAssertEqual(FrontMatterPlan.detect(in: package)?.roles, [.primaryPreface, .cut])
        XCTAssertEqual(WorkMetaExtractor.extract(from: package)?.authors.first?.name, "Fixture Author")
        let statsHTML = "<p>By: Fixture Author</p><p>Rated: T - Language: English - Genre: Adventure - Characters: A-B, C - Reviews: 4 - Favs: 2</p><p>Exported with the assistance of FicHub.net</p>"
        let statsPackage = try makePackage([statsHTML], metadata: ["title": ["Fixture Title"]])
        let extracted = try XCTUnwrap(WorkMetaExtractor.extract(from: statsPackage))
        XCTAssertEqual(extracted.stats.first(where: { $0.label == "Reviews" })?.value, "4")
        XCTAssertTrue(extracted.stats.contains(where: { $0.label == "Characters" && $0.value == "A-B, C" }))
    }

    func testRendererEscapesValuesAndKeepsOnlySafeSummaryMarkup() {
        let data = WorkMeta(
            title: "<script>Title</script>", authors: [Person(name: "A & B", url: URL(string: "javascript:alert(1)"))],
            siteLabel: "Archive of Our Own", sourceURL: URL(string: "https://archiveofourown.org/works/1"),
            summaryHTML: "<p>Safe <em>text</em><img src='x'/><script>evil()</script></p>", notesHTML: nil,
            rows: [.init(label: "Rating", values: [.init(text: "General & Teen", href: nil)], isWide: false, kind: "rating")], stats: [])
        let html = FanficPrefaceRenderer.html(data: data)
        XCTAssertTrue(html.contains("&lt;script&gt;Title&lt;/script&gt;"))
        XCTAssertTrue(html.contains("A &amp; B"))
        XCTAssertTrue(html.contains("<p>Safe <em>text</em></p>"))
        XCTAssertFalse(html.contains("evil()"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertTrue(html.contains("General &amp; Teen"))
    }

    func testVisibleResolutionSkipsCutsAndReportsCounts() {
        let plan = FrontMatterPlan(roles: [.primaryPreface, .cut, .chapter, .backMatter])
        XCTAssertEqual(plan.resolveVisible(from: 1, forward: true), 2)
        XCTAssertEqual(plan.resolveVisible(from: 1, forward: false), 0)
        XCTAssertEqual(plan.visibleOrdinal(of: 2).position, 2)
        XCTAssertEqual(plan.frontCount, 2)
        XCTAssertEqual(plan.backCount, 1)
    }

    func testSourceProfilesTagOnlyWhitespaceParagraphsAndSelectGeneratorCSS() {
        let html = "<p> </p><p>&nbsp;</p><p></p><p>words</p>"
        let tagged = SourceProfile.tagFanficSpacerParagraphs(in: html, generator: .ao3Native)
        XCTAssertTrue(tagged.contains("<p class=\"hc-spacer\"> </p>"))
        XCTAssertTrue(tagged.contains("<p class=\"hc-spacer\">&nbsp;</p>"))
        XCTAssertTrue(tagged.contains("<p></p>"))
        XCTAssertTrue(tagged.contains("<p>words</p>"))
        XCTAssertTrue(SourceProfile.forGenerator(.gutenberg)?.css.contains(".pagenum,.sidenote") == true)
        XCTAssertTrue(SourceProfile.forGenerator(.standardEbooks)?.css.contains("span.i2") == true)
        XCTAssertTrue(SourceProfile.forGenerator(.wikisource)?.css.contains(".wst-dhr") == true)
        XCTAssertNil(SourceProfile.forGenerator(.unknown))
    }

    private func makePackage(_ chapters: [String], metadata: [String: [String]] = [:]) throws -> EPUBPackage {
        let root = try EPUBFixture.makeRoot(in: temporaryDirectory, chapters: chapters)
        let parsed = try EPUBParser().parsePackage(at: root)
        return EPUBPackage(rootFolder: parsed.rootFolder, spineURLs: parsed.spineURLs, title: metadata["title"]?.first ?? "Fixture Title",
                           author: "", coverURL: nil, spine: parsed.spine, metadata: metadata)
    }
}
