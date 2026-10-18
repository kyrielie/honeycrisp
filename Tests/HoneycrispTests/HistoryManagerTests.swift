import Foundation
import XCTest
@testable import Honeycrisp

final class HistoryManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HoneycrispHistoryManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordMovesBookToFrontAndPreservesSavedProgressAndPosition() {
        let manager = makeManager()
        let firstURL = URL(fileURLWithPath: "/books/first.epub")
        let secondURL = URL(fileURLWithPath: "/books/second.epub")

        manager.record(url: firstURL, title: "First")
        manager.updateProgress(url: firstURL, percent: 57)
        manager.updatePosition(url: firstURL, spineIndex: 3, characterOffset: 987)
        manager.record(url: secondURL, title: "Second")
        manager.record(url: firstURL, title: "First, Updated")

        XCTAssertEqual(manager.entries.map(\.url), [firstURL, secondURL])
        XCTAssertEqual(manager.entries[0].title, "First, Updated")
        XCTAssertEqual(manager.entries[0].readingProgressPercent, 57)
        XCTAssertEqual(manager.savedPosition(for: firstURL)?.spineIndex, 3)
        XCTAssertEqual(manager.savedPosition(for: firstURL)?.characterOffset, 987)
    }

    func testProgressAndPositionUpdatesClampNegativeAndOversizedValues() {
        let manager = makeManager()
        let url = URL(fileURLWithPath: "/books/book.epub")
        manager.record(url: url, title: "Book")

        manager.updateProgress(url: url, percent: 120)
        manager.updatePosition(url: url, spineIndex: 2, characterOffset: -10)

        XCTAssertEqual(manager.entries.first?.readingProgressPercent, 100)
        XCTAssertEqual(manager.savedPosition(for: url)?.characterOffset, 0)

        manager.updateProgress(url: url, percent: -5)
        XCTAssertEqual(manager.entries.first?.readingProgressPercent, 0)
    }

    func testUpdatesForUnknownURLDoNotCreateHistoryEntries() {
        let manager = makeManager()
        let url = URL(fileURLWithPath: "/books/not-opened.epub")

        manager.updateProgress(url: url, percent: 50)
        manager.updatePosition(url: url, spineIndex: 1, characterOffset: 10)

        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertNil(manager.savedPosition(for: url))
    }

    func testHistoryIsCappedAtConfiguredEntryLimit() {
        let manager = makeManager(maxEntries: 3)
        let urls = (0..<4).map { URL(fileURLWithPath: "/books/\($0).epub") }

        for (index, url) in urls.enumerated() {
            manager.record(url: url, title: "Book \(index)")
        }

        XCTAssertEqual(manager.entries.count, 3)
        XCTAssertEqual(manager.entries.map(\.url), Array(urls.suffix(3).reversed()))
    }

    func testClearAllPersistsAnEmptyHistory() {
        let manager = makeManager()
        manager.record(url: URL(fileURLWithPath: "/books/book.epub"), title: "Book")

        manager.clearAll()

        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertTrue(makeManager().entries.isEmpty)
    }

    func testHistoryManagerReloadsSavedEntriesFromDefaults() {
        let firstManager = makeManager()
        let url = URL(fileURLWithPath: "/books/book.epub")
        firstManager.record(url: url, title: "Book")
        firstManager.updatePosition(url: url, spineIndex: 2, characterOffset: 456)

        let reloadedManager = makeManager()

        XCTAssertEqual(reloadedManager.entries.count, 1)
        XCTAssertEqual(reloadedManager.savedPosition(for: url)?.spineIndex, 2)
        XCTAssertEqual(reloadedManager.savedPosition(for: url)?.characterOffset, 456)
    }

    private func makeManager(maxEntries: Int = 100) -> HistoryManager {
        HistoryManager(defaults: defaults, key: "history", maxEntries: maxEntries)
    }
}
