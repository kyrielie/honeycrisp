import Foundation
import XCTest
@testable import Honeycrisp

final class BookmarkManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HoneycrispBookmarkTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBookmarksPersistByBookAndSupportRenameAndRemove() {
        let firstURL = URL(fileURLWithPath: "/books/one.epub")
        let secondURL = URL(fileURLWithPath: "/books/two.epub")
        let manager = makeManager()
        let first = manager.add(bookURL: firstURL, label: "Chapter 2 · 2", spineIndex: 1, characterOffset: 87, chapterTitle: "Chapter 2")
        manager.add(bookURL: secondURL, label: "Start", spineIndex: 0, characterOffset: 0, chapterTitle: nil)

        let reloaded = makeManager()
        XCTAssertEqual(reloaded.bookmarks(for: firstURL).count, 1)
        XCTAssertEqual(reloaded.bookmarks(for: firstURL).first?.spineIndex, 1)
        XCTAssertEqual(reloaded.bookmarks(for: firstURL).first?.characterOffset, 87)
        XCTAssertEqual(reloaded.bookmarks(for: secondURL).count, 1)

        reloaded.rename(id: first.id, to: "Return here")
        XCTAssertEqual(makeManager().bookmarks(for: firstURL).first?.label, "Return here")
        makeManager().remove(id: first.id)
        XCTAssertTrue(makeManager().bookmarks(for: firstURL).isEmpty)
    }

    func testCorruptBookmarkDataDoesNotAffectHistoryPersistence() {
        defaults.set(Data("not-json".utf8), forKey: "bookmarks")
        let history = HistoryManager(defaults: defaults, key: "history")
        history.record(url: URL(fileURLWithPath: "/books/book.epub"), title: "Book")

        XCTAssertTrue(makeManager().bookmarks(for: URL(fileURLWithPath: "/books/book.epub")).isEmpty)
        XCTAssertEqual(HistoryManager(defaults: defaults, key: "history").entries.map(\.title), ["Book"])
    }

    private func makeManager() -> BookmarkManager {
        BookmarkManager(defaults: defaults, key: "bookmarks")
    }
}
