import Foundation
import XCTest
@testable import Honeycrisp

/// Coverage for `AO3MetadataExtractor`. Fixtures are synthetic: the markup shape follows the AO3 EPUB
/// preface (a `dl.tags` list of `dt`/`dd` pairs plus a `p.message` work link), the values are invented.
final class AO3MetadataExtractorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AO3MetadataExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - extract(from: html)

    func testFullPrefacePopulatesEveryField() throws {
        let html = makePreface(pairs: """
            <dt>Rating:</dt><dd><a href="/r">Explicit</a></dd>
            <dt>Archive Warning:</dt><dd><a href="/w">No Archive Warnings Apply</a></dd>
            <dt>Category:</dt><dd><a href="/c">M/M</a></dd>
            <dt>Fandom:</dt><dd><a href="/t/1">Fandom A</a></dd>
            <dt>Relationship:</dt><dd><a href="/t/2">Person One/Person Two</a></dd>
            <dt>Character:</dt><dd><a href="/t/3">Person One</a>, <a href="/t/4">Person Two</a></dd>
            <dt>Additional Tags:</dt><dd><a href="/t/5">Tag One</a>, <a href="/t/6">Tag Two</a></dd>
            <dt>Language:</dt><dd>English</dd>
            <dt>Stats:</dt><dd>Published: 2020-06-22\nCompleted: 2020-07-11\nWords: 21,069\nChapters: 5/5</dd>
            """)

        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.storyURL, "https://archiveofourown.org/works/1234567")
        XCTAssertEqual(record.workID, "1234567")
        XCTAssertEqual(record.rating, "Explicit")
        XCTAssertEqual(record.warnings, ["No Archive Warnings Apply"])
        XCTAssertEqual(record.categories, ["M/M"])
        XCTAssertEqual(record.fandoms, ["Fandom A"])
        XCTAssertEqual(record.relationships, ["Person One/Person Two"])
        XCTAssertEqual(record.characters, ["Person One", "Person Two"])
        XCTAssertEqual(record.additionalTags, ["Tag One", "Tag Two"])
        XCTAssertEqual(record.language, "English")
        XCTAssertEqual(record.publishedDate, "2020-06-22")
        XCTAssertEqual(record.updatedDate, "2020-07-11")
        XCTAssertEqual(record.wordCount, 21069)
        XCTAssertEqual(record.chapterCurrent, 5)
        XCTAssertEqual(record.chapterTotal, 5)
        XCTAssertTrue(record.isComplete)
    }

    func testNoDlTagsReturnsNil() {
        XCTAssertNil(AO3MetadataExtractor.extract(from: "<body><p>Not a preface.</p></body>"))
    }

    func testPluralAndSingularFieldNamesBothMatch() throws {
        let html = makePreface(pairs: """
            <dt>Fandoms:</dt><dd><a href="/t/1">Fandom A</a>, <a href="/t/2">Fandom B</a></dd>
            <dt>Relationships:</dt><dd><a href="/t/3">Pair</a></dd>
            <dt>Additional Tag:</dt><dd><a href="/t/4">Solo Tag</a></dd>
            <dt>Collection:</dt><dd><a href="/c/1">Collection One</a></dd>
            """)
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.fandoms, ["Fandom A", "Fandom B"])
        XCTAssertEqual(record.relationships, ["Pair"])
        XCTAssertEqual(record.additionalTags, ["Solo Tag"])
        XCTAssertEqual(record.collections, ["Collection One"])
    }

    func testUnrecognizedRatingWarningAndCategoryAreKeptAsWritten() throws {
        let html = makePreface(pairs: """
            <dt>Rating:</dt><dd><a href="/r">Some New Rating</a></dd>
            <dt>Archive Warning:</dt><dd><a href="/w">Creator Chose Not To Use Archive Warnings</a></dd>
            <dt>Category:</dt><dd><a href="/c">Other</a>, <a href="/c2">Brand New Category</a></dd>
            """)
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.rating, "Some New Rating")
        XCTAssertEqual(record.warnings, ["Creator Chose Not To Use Archive Warnings"])
        XCTAssertEqual(record.categories, ["Other", "Brand New Category"])
    }

    func testEmptyValuesProduceNoEntries() throws {
        let html = makePreface(pairs: """
            <dt>Rating:</dt><dd> </dd>
            <dt>Language:</dt><dd></dd>
            <dt>Fandom:</dt><dd><a href="/t/1"> </a></dd>
            """)
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertNil(record.rating)
        XCTAssertNil(record.language)
        XCTAssertEqual(record.fandoms, [])
    }

    // MARK: - Work link

    func testHTTPWorkLinkIsUpgradedToHTTPS() throws {
        let html = makePreface(pairs: statsPair(), workHref: "http://archiveofourown.org/works/111")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.storyURL, "https://archiveofourown.org/works/111")
        XCTAssertEqual(record.workID, "111")
    }

    func testRelativeWorkLinkBecomesAbsolute() throws {
        let html = makePreface(pairs: statsPair(), workHref: "/works/222")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.storyURL, "https://archiveofourown.org/works/222")
    }

    func testWorkLinkOutsideMessageParagraphIsFound() throws {
        let html = """
        <body><a href="https://archiveofourown.org/works/333">elsewhere</a>
        <dl class="tags">\(statsPair())</dl></body>
        """
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.workID, "333")
    }

    func testMissingWorkLinkLeavesURLAndIDNil() throws {
        let html = "<body><dl class=\"tags\">\(statsPair())</dl></body>"
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertNil(record.storyURL)
        XCTAssertNil(record.workID)
    }

    // MARK: - Series

    func testSeriesWithTwoEntriesInOneDD() throws {
        let html = makePreface(pairs: """
            <dt>Series:</dt>
            <dd>Part 7 of <a href="/series/100">Series One</a>,
            Part 1 of <a href="/series/200">Series Two</a></dd>
            """)
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.series, [
            AO3MetadataRecord.SeriesEntry(name: "Series One", index: 7, ao3ID: "100"),
            AO3MetadataRecord.SeriesEntry(name: "Series Two", index: 1, ao3ID: "200"),
        ])
    }

    func testSeriesWithoutPartPrefixProducesNoEntries() throws {
        let html = makePreface(pairs: "<dt>Series:</dt><dd><a href=\"/series/9\">Orphan Link</a></dd>")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.series, [])
    }

    // MARK: - Stats

    func testStatsWithoutCompletedOrUpdated() throws {
        let html = makePreface(pairs: "<dt>Stats:</dt><dd>Published: 2020-01-02\nWords: 3,261\nChapters: 1/1</dd>")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.publishedDate, "2020-01-02")
        XCTAssertNil(record.updatedDate)
        XCTAssertEqual(record.wordCount, 3261)
        XCTAssertTrue(record.isComplete)
    }

    func testUnknownChapterTotalWithoutCompletedDateIsInProgress() throws {
        let html = makePreface(pairs: "<dt>Stats:</dt><dd>Published: 2020-01-02\nUpdated: 2020-02-03\nWords: 900\nChapters: 3/?</dd>")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.chapterCurrent, 3)
        XCTAssertNil(record.chapterTotal)
        XCTAssertEqual(record.updatedDate, "2020-02-03")
        XCTAssertFalse(record.isComplete)
    }

    func testCompletedDateMarksCompleteWhenChapterTotalUnknown() throws {
        let html = makePreface(pairs: "<dt>Stats:</dt><dd>Published: 2020-01-02\nCompleted: 2020-03-04\nWords: 500\nChapters: 5/?</dd>")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertNil(record.chapterTotal)
        XCTAssertTrue(record.isComplete)
    }

    func testKudosAreParsedFromStats() throws {
        let html = makePreface(pairs: "<dt>Stats:</dt><dd>Published: 2020-01-02\nWords: 10\nChapters: 1/1\nKudos: 1,234</dd>")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.kudosCount, 1234)
    }

    func testChaptersDefaultToOneOfOneWhenAbsent() throws {
        let html = makePreface(pairs: "<dt>Stats:</dt><dd>Published: 2020-01-02\nWords: 100</dd>")
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        XCTAssertEqual(record.chapterCurrent, 1)
        XCTAssertEqual(record.chapterTotal, 1)
    }

    // MARK: - Prefilter

    func testMightContainPrefaceRulesOutPlainChapters() {
        XCTAssertFalse(AO3MetadataExtractor.mightContainPreface("<p>Just prose with tags in it.</p>"))
        XCTAssertFalse(AO3MetadataExtractor.mightContainPreface("<dl><dt>Term</dt><dd>Definition</dd></dl>"))
        XCTAssertTrue(AO3MetadataExtractor.mightContainPreface(makePreface(pairs: statsPair())))
    }

    // MARK: - extract(from: package)

    func testExtractFromPackageReadsFirstSpineItem() throws {
        let package = try makePackage(spine: [makePreface(pairs: statsPair()), "<p>Chapter</p>"])
        XCTAssertEqual(AO3MetadataExtractor.extract(from: package)?.workID, "1234567")
    }

    func testExtractFromPackageFallsBackWithinFiveSpineItems() throws {
        var spine = Array(repeating: "<p>Prose</p>", count: 5)
        spine[4] = makePreface(pairs: statsPair())
        XCTAssertNotNil(AO3MetadataExtractor.extract(from: try makePackage(spine: spine)))
    }

    func testExtractFromPackageIgnoresPrefaceBeyondFifthSpineItem() throws {
        var spine = Array(repeating: "<p>Prose</p>", count: 6)
        spine[5] = makePreface(pairs: statsPair())
        XCTAssertNil(AO3MetadataExtractor.extract(from: try makePackage(spine: spine)))
    }

    func testExtractFromPackageSkipsUnreadableSpineItem() throws {
        let package = try makePackage(spine: [makePreface(pairs: statsPair())])
        let missing = root.appendingPathComponent("missing.xhtml")
        let withMissingFirst = EPUBPackage(
            rootFolder: root,
            spineURLs: [missing] + package.spineURLs,
            title: "t",
            author: "a",
            coverURL: nil
        )
        XCTAssertNotNil(AO3MetadataExtractor.extract(from: withMissingFirst))
    }

    func testExtractFromPackageReturnsNilForNonAO3Book() throws {
        XCTAssertNil(AO3MetadataExtractor.extract(from: try makePackage(spine: ["<p>One</p>", "<p>Two</p>"])))
    }

    func testExtractFromPackageDecodesWindows1252File() throws {
        let html = makePreface(pairs: "<dt>Fandom:</dt><dd><a href=\"/t/1\">Caf\u{E9} Fandom</a></dd>")
        let url = root.appendingPathComponent("cp1252.xhtml")
        try XCTUnwrap(html.data(using: .windowsCP1252)).write(to: url)
        let package = EPUBPackage(rootFolder: root, spineURLs: [url], title: "t", author: "a", coverURL: nil)
        XCTAssertEqual(AO3MetadataExtractor.extract(from: package)?.fandoms, ["Caf\u{E9} Fandom"])
    }

    // MARK: - Summary

    func testExtractSummaryJoinsParagraphsWithABlankLine() {
        let html = makeTitlePage(summaryParagraphs: ["First paragraph.", "Second paragraph."])
        XCTAssertEqual(AO3MetadataExtractor.extractSummary(from: html), "First paragraph.\n\nSecond paragraph.")
    }

    func testExtractSummaryAcceptsHeadingElementsAndAnyCase() {
        let html = makeTitlePage(headingTag: "h3", headingText: "SUMMARY", summaryParagraphs: ["Text."])
        XCTAssertEqual(AO3MetadataExtractor.extractSummary(from: html), "Text.")
    }

    func testExtractSummaryRequiresABlockquoteDirectlyAfterTheHeading() {
        let html = "<body><p>Summary</p><p>Not a blockquote.</p><blockquote><p>Elsewhere.</p></blockquote></body>"
        XCTAssertNil(AO3MetadataExtractor.extractSummary(from: html))
    }

    func testExtractSummaryUsesBlockquoteTextWhenThereAreNoParagraphs() {
        let html = "<body><p>Summary</p><blockquote>Plain text summary.</blockquote></body>"
        XCTAssertEqual(AO3MetadataExtractor.extractSummary(from: html), "Plain text summary.")
    }

    func testMightContainSummaryRulesOutPlainChapters() {
        XCTAssertFalse(AO3MetadataExtractor.mightContainSummary("<p>Summary of events.</p>"))
        XCTAssertFalse(AO3MetadataExtractor.mightContainSummary("<blockquote>A quote.</blockquote>"))
        XCTAssertTrue(AO3MetadataExtractor.mightContainSummary(makeTitlePage(summaryParagraphs: ["x"])))
    }

    func testPackageSummaryComesFromATitlePageBeforeThePreface() throws {
        let package = try makePackage(spine: [
            makeTitlePage(summaryParagraphs: ["The summary."]),
            makePreface(pairs: statsPair()),
        ])
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: package))
        XCTAssertEqual(record.summary, "The summary.")
        XCTAssertEqual(record.workID, "1234567")
    }

    func testPackageSummaryComesFromATitlePageAfterThePreface() throws {
        let package = try makePackage(spine: [
            makePreface(pairs: statsPair()),
            makeTitlePage(summaryParagraphs: ["Later summary."]),
        ])
        XCTAssertEqual(AO3MetadataExtractor.extract(from: package)?.summary, "Later summary.")
    }

    func testPrefaceWithoutASummaryLeavesSummaryNil() throws {
        let package = try makePackage(spine: [makePreface(pairs: statsPair()), "<p>Chapter</p>"])
        XCTAssertNil(AO3MetadataExtractor.extract(from: package)?.summary)
    }

    func testSummaryAloneDoesNotMakeABookAO3() throws {
        let package = try makePackage(spine: [makeTitlePage(summaryParagraphs: ["Looks like a summary."]), "<p>Chapter</p>"])
        XCTAssertNil(AO3MetadataExtractor.extract(from: package))
    }

    // MARK: - Fixtures

    private func statsPair() -> String {
        "<dt>Stats:</dt><dd>Published: 2020-01-01\nWords: 100\nChapters: 1/1</dd>"
    }

    private func makePreface(pairs: String, workHref: String = "https://archiveofourown.org/works/1234567") -> String {
        """
        <body class="calibre">
          <div id="preface">
            <h2 class="toc-heading">Preface</h2>
            <p class="message"><b>A Test Work</b><br/>Posted originally at <a href="\(workHref)">the work page</a>.</p>
            <div><dl class="tags">\(pairs)</dl></div>
          </div>
        </body>
        """
    }

    private func makeTitlePage(
        headingTag: String = "p",
        headingText: String = "Summary",
        summaryParagraphs: [String]
    ) -> String {
        let paragraphs = summaryParagraphs.map { "<p>\($0)</p>" }.joined()
        return """
        <body>
          <div class="meta"><h1>A Test Work</h1><div class="byline">by Someone</div></div>
          <\(headingTag)>\(headingText)</\(headingTag)>
          <blockquote class="userstuff">\(paragraphs)</blockquote>
        </body>
        """
    }

    private func makePackage(spine: [String]) throws -> EPUBPackage {
        var urls: [URL] = []
        for (index, html) in spine.enumerated() {
            let url = root.appendingPathComponent("item\(index).xhtml")
            try html.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        return EPUBPackage(rootFolder: root, spineURLs: urls, title: "t", author: "a", coverURL: nil)
    }
}
