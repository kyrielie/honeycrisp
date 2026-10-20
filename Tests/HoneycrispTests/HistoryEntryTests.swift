import Foundation
import XCTest
@testable import Honeycrisp

final class HistoryEntryTests: XCTestCase {
    func testLegacyHistoryDecodesWithDefaultRestorePosition() throws {
        let legacyEntry: [String: Any] = [
            "id": UUID().uuidString,
            "url": URL(fileURLWithPath: "/books/legacy.epub").absoluteString,
            "title": "Legacy Book",
            "openedAt": 1_700_000_000.0,
            "readingProgressPercent": 42,
        ]
        let data = try JSONSerialization.data(withJSONObject: [legacyEntry])
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: data)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Legacy Book")
        XCTAssertEqual(entries[0].readingProgressPercent, 42)
        XCTAssertEqual(entries[0].lastSpineIndex, 0)
        XCTAssertEqual(entries[0].lastCharacterOffset, 0)
        XCTAssertEqual(entries[0].lastResourceFraction, 0)
        XCTAssertEqual(entries[0].anchorLayout, EPUBAnchor.legacyLayout)
    }

    func testNewEntryCarriesCurrentAnchorLayout() {
        let entry = HistoryEntry(url: URL(fileURLWithPath: "/books/book.epub"), title: "Book")
        XCTAssertEqual(entry.anchorLayout, EPUBAnchor.currentLayout)
    }

    func testHistoryEntryRoundTripPreservesNonDefaultAnchorLayout() throws {
        var entry = HistoryEntry(url: URL(fileURLWithPath: "/books/book.epub"), title: "Book")
        entry.anchorLayout = 7

        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))

        XCTAssertEqual(decoded.anchorLayout, 7)
    }

    func testHistoryEntryRoundTripPreservesRestorePosition() throws {
        var entry = HistoryEntry(url: URL(fileURLWithPath: "/books/book.epub"), title: "Book")
        entry.readingProgressPercent = 73
        entry.lastSpineIndex = 4
        entry.lastCharacterOffset = 1_234
        entry.lastResourceFraction = 0.42

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.url, entry.url)
        XCTAssertEqual(decoded.readingProgressPercent, 73)
        XCTAssertEqual(decoded.lastSpineIndex, 4)
        XCTAssertEqual(decoded.lastCharacterOffset, 1_234)
        XCTAssertEqual(decoded.lastResourceFraction, 0.42, accuracy: 0.0001)
    }
}
