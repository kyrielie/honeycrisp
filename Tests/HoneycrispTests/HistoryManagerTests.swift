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
        XCTAssertEqual(manager.savedPosition(for: firstURL)?.anchorLayout, EPUBAnchor.currentLayout)
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

    func testCorruptElementAmongValidOnesLoadsTheValidOnesAndSurvivesSave() throws {
        let kept = HistoryEntry(url: URL(fileURLWithPath: "/books/kept.epub"), title: "Kept")
        defaults.set(try blob(valid: [kept], junkElements: 1), forKey: "history")

        let manager = makeManager()
        XCTAssertEqual(manager.entries.map(\.title), ["Kept"])

        manager.record(url: URL(fileURLWithPath: "/books/new.epub"), title: "New")
        manager.updateProgress(url: URL(fileURLWithPath: "/books/new.epub"), percent: 10)

        let stored = try storedElements()
        XCTAssertEqual(stored.count, 3)
        XCTAssertTrue(stored.contains { $0["junk"] as? Int == 0 })

        let reloaded = makeManager()
        XCTAssertEqual(reloaded.entries.map(\.title), ["New", "Kept"])
        XCTAssertTrue(
            StorageQuarantine.quarantinedKeys(for: "history", defaults: defaults).isEmpty,
            "A bad element is preserved in place and needs no quarantine copy")
    }

    func testWholeBlobCorruptionIsPreservedBeforeFirstSave() {
        let junk = Data("not-json".utf8)
        defaults.set(junk, forKey: "history")

        let manager = makeManager()
        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "history"), junk, "Loading alone must not write")
        XCTAssertTrue(StorageQuarantine.quarantinedKeys(for: "history", defaults: defaults).isEmpty)

        manager.record(url: URL(fileURLWithPath: "/books/book.epub"), title: "Book")

        let copies = StorageQuarantine.quarantinedKeys(for: "history", defaults: defaults)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(defaults.data(forKey: copies[0].key), junk)
        XCTAssertEqual(makeManager().entries.map(\.title), ["Book"])
    }

    func testUnreadableElementsCountTowardTheCapAndAreDroppedFirst() throws {
        let entries = (0..<2).map {
            HistoryEntry(url: URL(fileURLWithPath: "/books/\($0).epub"), title: "Book \($0)")
        }
        defaults.set(try blob(valid: entries, junkElements: 2), forKey: "history")

        let manager = makeManager(maxEntries: 3)
        manager.record(url: URL(fileURLWithPath: "/books/new.epub"), title: "New")

        XCTAssertEqual(manager.entries.count, 3)
        XCTAssertEqual(try storedElements().count, 3, "No room is left for unreadable elements")
        XCTAssertFalse(try storedElements().contains { $0["junk"] != nil })
    }

    func testUnreadableElementsFillRemainingRoomUnderTheCap() throws {
        let entry = HistoryEntry(url: URL(fileURLWithPath: "/books/0.epub"), title: "Book 0")
        defaults.set(try blob(valid: [entry], junkElements: 3), forKey: "history")

        let manager = makeManager(maxEntries: 3)
        manager.record(url: URL(fileURLWithPath: "/books/new.epub"), title: "New")

        XCTAssertEqual(manager.entries.count, 2)
        let stored = try storedElements()
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.filter { $0["junk"] != nil }.count, 1)
    }

    func testClearAllRemovesUnreadableElementsToo() throws {
        let entry = HistoryEntry(url: URL(fileURLWithPath: "/books/0.epub"), title: "Book 0")
        defaults.set(try blob(valid: [entry], junkElements: 2), forKey: "history")

        let manager = makeManager()
        manager.clearAll()

        XCTAssertTrue(try storedElements().isEmpty)
        XCTAssertTrue(makeManager().entries.isEmpty)
    }

    func testRecordCarriesAnchorLayoutForwardWithTheSavedPosition() throws {
        let url = URL(fileURLWithPath: "/books/old.epub")
        var old = HistoryEntry(url: url, title: "Old")
        old.anchorLayout = 0
        old.lastCharacterOffset = 500
        defaults.set(try JSONEncoder().encode([old]), forKey: "history")

        let manager = makeManager()
        manager.record(url: url, title: "Old, reopened")

        XCTAssertEqual(manager.entries[0].anchorLayout, 0)
        XCTAssertEqual(manager.savedPosition(for: url)?.characterOffset, 500)
    }

    func testUpdatePositionStampsTheCurrentAnchorLayout() throws {
        let url = URL(fileURLWithPath: "/books/old.epub")
        var old = HistoryEntry(url: url, title: "Old")
        old.anchorLayout = 0
        defaults.set(try JSONEncoder().encode([old]), forKey: "history")

        let manager = makeManager()
        manager.updatePosition(url: url, spineIndex: 1, characterOffset: 10)

        XCTAssertEqual(manager.entries[0].anchorLayout, EPUBAnchor.currentLayout)
        XCTAssertEqual(makeManager().entries[0].anchorLayout, EPUBAnchor.currentLayout)
    }

    private func blob(valid: [HistoryEntry], junkElements: Int) throws -> Data {
        let encoder = JSONEncoder()
        var pieces = try valid.map { try encoder.encode($0) }
        pieces.append(contentsOf: (0..<junkElements).map { Data("{\"junk\":\($0)}".utf8) })
        var output = Data("[".utf8)
        for (index, piece) in pieces.enumerated() {
            if index > 0 { output.append(0x2C) }
            output.append(piece)
        }
        output.append(contentsOf: "]".utf8)
        return output
    }

    private func storedElements() throws -> [[String: Any]] {
        let stored = try XCTUnwrap(defaults.data(forKey: "history"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
    }

    private func makeManager(maxEntries: Int = 100) -> HistoryManager {
        HistoryManager(defaults: defaults, key: "history", maxEntries: maxEntries)
    }
}
