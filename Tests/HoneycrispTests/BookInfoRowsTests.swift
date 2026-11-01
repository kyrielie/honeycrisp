import Foundation
import XCTest
@testable import Honeycrisp

final class BookInfoRowsTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")

    // MARK: - Base rows

    func testBaseRowsForPlainBookKeepTheSheetsOriginalRowsAndOrder() {
        let package = makePackage(spineCount: 4, publisher: "A Press", date: "2020-01-02", language: "en", identifier: "id-1")
        let rows = BookInfoRows.baseRows(package: package, formatName: "EPUB Document", ao3: nil)
        XCTAssertEqual(rows, [
            BookInfoRow(label: "Format", value: "EPUB Document"),
            BookInfoRow(label: "Chapters", value: "4"),
            BookInfoRow(label: "Publisher", value: "A Press"),
            BookInfoRow(label: "Date", value: "2020-01-02"),
            BookInfoRow(label: "Language", value: "en"),
            BookInfoRow(label: "Identifier", value: "id-1"),
        ])
    }

    func testMissingBaseFieldsShowPlaceholder() {
        let rows = BookInfoRows.baseRows(package: makePackage(spineCount: 1), formatName: "EPUB Document", ao3: nil)
        XCTAssertEqual(rows.first { $0.label == "Publisher" }?.value, BookInfoRows.placeholder)
        XCTAssertEqual(rows.first { $0.label == "Date" }?.value, BookInfoRows.placeholder)
        XCTAssertEqual(rows.first { $0.label == "Language" }?.value, BookInfoRows.placeholder)
        XCTAssertEqual(rows.first { $0.label == "Identifier" }?.value, BookInfoRows.placeholder)
    }

    func testSpineChapterCountIsDroppedWhenAO3MetadataIsPresent() {
        let rows = BookInfoRows.baseRows(package: makePackage(spineCount: 4), formatName: "EPUB Document", ao3: AO3MetadataRecord())
        XCTAssertNil(rows.first { $0.label == "Chapters" })
        XCTAssertEqual(rows.map(\.label), ["Format", "Publisher", "Date", "Language", "Identifier"])
    }

    func testLanguageFallsBackToAO3OnlyWhenThePackageHasNone() {
        var record = AO3MetadataRecord()
        record.language = "English"
        let without = BookInfoRows.baseRows(package: makePackage(spineCount: 1), formatName: "F", ao3: record)
        XCTAssertEqual(without.first { $0.label == "Language" }?.value, "English")
        let with = BookInfoRows.baseRows(package: makePackage(spineCount: 1, language: "en"), formatName: "F", ao3: record)
        XCTAssertEqual(with.first { $0.label == "Language" }?.value, "en")
    }

    // MARK: - Description

    func testDescriptionIsTheLastBaseRowWhenThereIsNoAO3Summary() {
        let rows = BookInfoRows.baseRows(
            package: makePackage(spineCount: 1), formatName: "F", ao3: nil, description: "About the book."
        )
        XCTAssertEqual(rows.last, BookInfoRow(label: "Description", value: "About the book."))
    }

    func testDescriptionIsShownForAnAO3BookWithoutASummary() {
        let rows = BookInfoRows.baseRows(
            package: makePackage(spineCount: 1), formatName: "F", ao3: AO3MetadataRecord(), description: "About the book."
        )
        XCTAssertEqual(value("Description", in: rows), "About the book.")
    }

    func testDescriptionIsOmittedWhenAnAO3SummaryIsShown() {
        var record = AO3MetadataRecord()
        record.summary = "The summary."
        let rows = BookInfoRows.baseRows(
            package: makePackage(spineCount: 1), formatName: "F", ao3: record, description: "About the book."
        )
        XCTAssertNil(value("Description", in: rows))
    }

    func testEmptyOrMissingDescriptionAddsNoRow() {
        for description in [nil, ""] as [String?] {
            let rows = BookInfoRows.baseRows(
                package: makePackage(spineCount: 1), formatName: "F", ao3: nil, description: description
            )
            XCTAssertNil(value("Description", in: rows))
        }
    }

    // MARK: - AO3 rows

    func testAO3RowsAppearInDisplayOrderWithFormattedValues() {
        var record = AO3MetadataRecord()
        record.storyURL = "https://archiveofourown.org/works/1"
        record.rating = "Mature"
        record.warnings = ["Warning A", "Warning B"]
        record.categories = ["F/M"]
        record.fandoms = ["Fandom A"]
        record.relationships = ["Pair One"]
        record.characters = ["Person One", "Person Two"]
        record.additionalTags = ["Tag One"]
        record.collections = ["Collection One"]
        record.summary = "A short summary."
        record.series = [
            AO3MetadataRecord.SeriesEntry(name: "Series One", index: 7, ao3ID: "1"),
            AO3MetadataRecord.SeriesEntry(name: "Series Two", index: 1, ao3ID: nil),
        ]
        record.wordCount = 21069
        record.chapterCurrent = 5
        record.chapterTotal = 5
        record.kudosCount = 1234
        record.isComplete = true
        record.publishedDate = "2020-06-22"
        record.updatedDate = "2020-07-11"

        let rows = BookInfoRows.ao3Rows(record, locale: enUS)
        XCTAssertEqual(rows.map(\.label), [
            "Rating", "Warnings", "Categories", "Fandoms", "Relationships", "Characters", "Tags", "Series",
            "Collections", "Summary", "Words", "Chapters", "Status", "Published", "Updated", "Kudos", "Link",
        ])
        XCTAssertEqual(value("Warnings", in: rows), "Warning A, Warning B")
        XCTAssertEqual(value("Series", in: rows), "Part 7 of Series One; Part 1 of Series Two")
        XCTAssertEqual(value("Summary", in: rows), "A short summary.")
        XCTAssertEqual(value("Words", in: rows), "21,069")
        XCTAssertEqual(value("Chapters", in: rows), "5/5")
        XCTAssertEqual(value("Status", in: rows), "Complete")
        XCTAssertEqual(value("Kudos", in: rows), "1,234")
        XCTAssertEqual(value("Link", in: rows), "https://archiveofourown.org/works/1")
    }

    func testAO3RowsOmitFieldsThatAreEmpty() {
        XCTAssertEqual(BookInfoRows.ao3Rows(AO3MetadataRecord(), locale: enUS), [])

        var record = AO3MetadataRecord()
        record.fandoms = ["Fandom A"]
        XCTAssertEqual(BookInfoRows.ao3Rows(record, locale: enUS), [BookInfoRow(label: "Fandoms", value: "Fandom A")])
    }

    func testUnknownChapterTotalShowsQuestionMarkAndInProgress() {
        var record = AO3MetadataRecord()
        record.chapterCurrent = 3
        record.chapterTotal = nil
        record.isComplete = false
        let rows = BookInfoRows.ao3Rows(record, locale: enUS)
        XCTAssertEqual(value("Chapters", in: rows), "3/?")
        XCTAssertEqual(value("Status", in: rows), "In progress")
    }

    func testRowsFromExtractedPrefaceMatchTheRecord() throws {
        let html = """
        <body><p class="message"><a href="https://archiveofourown.org/works/9">w</a></p>
        <dl class="tags"><dt>Rating:</dt><dd><a href="/r">Teen And Up Audiences</a></dd>
        <dt>Stats:</dt><dd>Published: 2020-01-01\nWords: 1,500\nChapters: 2/?</dd></dl></body>
        """
        let record = try XCTUnwrap(AO3MetadataExtractor.extract(from: html))
        let rows = BookInfoRows.ao3Rows(record, locale: enUS)
        XCTAssertEqual(rows.map(\.label), ["Rating", "Words", "Chapters", "Status", "Published", "Link"])
        XCTAssertEqual(value("Words", in: rows), "1,500")
        XCTAssertEqual(value("Chapters", in: rows), "2/?")
    }

    // MARK: - Fixtures

    private func value(_ label: String, in rows: [BookInfoRow]) -> String? {
        rows.first { $0.label == label }?.value
    }

    private func makePackage(
        spineCount: Int,
        publisher: String? = nil,
        date: String? = nil,
        language: String? = nil,
        identifier: String? = nil
    ) -> EPUBPackage {
        let root = URL(fileURLWithPath: "/tmp/book-info-rows")
        let urls = (0..<spineCount).map { root.appendingPathComponent("item\($0).xhtml") }
        return EPUBPackage(
            rootFolder: root,
            spineURLs: urls,
            title: "t",
            author: "a",
            coverURL: nil,
            language: language,
            publisher: publisher,
            identifier: identifier,
            publicationDate: date
        )
    }
}
