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
        let first = manager.add(
            bookURL: firstURL, label: "Chapter 2 · 2", spineIndex: 1, characterOffset: 87, chapterTitle: "Chapter 2")
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

    func testCorruptElementAmongValidOnesLoadsTheValidOnesAndSurvivesSave() throws {
        let url = URL(fileURLWithPath: "/books/book.epub")
        let original = ReadingBookmark(
            bookURL: url, label: "Kept", spineIndex: 2, characterOffset: 40,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000.123456))
        let valid = try JSONEncoder().encode(original)
        var blob = Data("{\"version\":1,\"bookmarks\":[".utf8)
        blob.append(valid)
        blob.append(contentsOf: ",{\"id\":\"not-a-uuid\",\"weird\":1}]}".utf8)
        defaults.set(blob, forKey: "bookmarks")

        let manager = makeManager()
        XCTAssertEqual(manager.bookmarks.count, 1)
        XCTAssertEqual(manager.bookmarks.first?.createdAt, original.createdAt)

        manager.add(bookURL: url, label: "New", spineIndex: 0, characterOffset: 0, chapterTitle: nil)

        let stored = try XCTUnwrap(defaults.data(forKey: "bookmarks"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let elements = try XCTUnwrap(root["bookmarks"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 3)
        XCTAssertTrue(elements.contains { $0["weird"] as? Int == 1 })
        XCTAssertEqual(root["version"] as? Int, 1)

        let reloaded = makeManager()
        XCTAssertEqual(reloaded.bookmarks.count, 2)
        XCTAssertEqual(
            reloaded.bookmarks.first { $0.id == original.id }?.createdAt, original.createdAt)
        XCTAssertTrue(
            StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults).isEmpty,
            "A bad element is preserved in place and needs no quarantine copy")
    }

    func testNewerEnvelopeVersionIsPreservedBeforeOverwrite() throws {
        let url = URL(fileURLWithPath: "/books/book.epub")
        let existing = ReadingBookmark(
            bookURL: url, label: "From the future", spineIndex: 1, characterOffset: 5)
        var blob = Data("{\"version\":2,\"bookmarks\":[".utf8)
        blob.append(try JSONEncoder().encode(existing))
        blob.append(contentsOf: "]}".utf8)
        defaults.set(blob, forKey: "bookmarks")

        let manager = makeManager()
        XCTAssertEqual(manager.bookmarks.count, 1, "Decodable elements still load")
        XCTAssertTrue(StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults).isEmpty)

        manager.add(bookURL: url, label: "New", spineIndex: 0, characterOffset: 0, chapterTitle: nil)

        let copies = StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(defaults.data(forKey: copies[0].key), blob)

        manager.add(bookURL: url, label: "Newer", spineIndex: 0, characterOffset: 0, chapterTitle: nil)
        XCTAssertEqual(
            StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults).count, 1,
            "The original is preserved once, not on every save")
    }

    func testWholeBlobCorruptionIsPreservedBeforeFirstSave() {
        let junk = Data("not-json".utf8)
        defaults.set(junk, forKey: "bookmarks")

        let manager = makeManager()
        XCTAssertTrue(manager.bookmarks.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "bookmarks"), junk, "Loading alone must not write")
        XCTAssertTrue(StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults).isEmpty)

        manager.add(
            bookURL: URL(fileURLWithPath: "/books/book.epub"), label: "New", spineIndex: 0,
            characterOffset: 0, chapterTitle: nil)

        let copies = StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(defaults.data(forKey: copies[0].key), junk)
        XCTAssertEqual(makeManager().bookmarks.count, 1)
    }

    func testQuarantineKeepsOnlyNewestThreeCopies() {
        for index in 0..<5 {
            StorageQuarantine.preserve(
                Data("copy-\(index)".utf8), key: "bookmarks", defaults: defaults, reason: "test",
                now: Date(timeIntervalSince1970: 1_000 + Double(index)))
        }

        let copies = StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults)
        XCTAssertEqual(copies.count, StorageQuarantine.maxCopies)
        XCTAssertEqual(
            copies.map { String(decoding: defaults.data(forKey: $0.key) ?? Data(), as: UTF8.self) },
            ["copy-2", "copy-3", "copy-4"])
    }

    func testQuarantineNeverOverwritesOrPrunesTheNewestCopyWhenTheClockRepeats() {
        let sameInstant = Date(timeIntervalSince1970: 5_000)
        for index in 0..<4 {
            StorageQuarantine.preserve(
                Data("copy-\(index)".utf8), key: "bookmarks", defaults: defaults, reason: "test",
                now: sameInstant)
        }

        let copies = StorageQuarantine.quarantinedKeys(for: "bookmarks", defaults: defaults)
        XCTAssertEqual(
            copies.map { String(decoding: defaults.data(forKey: $0.key) ?? Data(), as: UTF8.self) },
            ["copy-1", "copy-2", "copy-3"])
    }

    func testLegacyBookmarkWithoutAnchorLayoutDecodesAsLegacyLayout() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "bookPath": "/books/legacy.epub",
            "label": "Legacy",
            "createdAt": 700_000_000.0,
            "spineIndex": 2,
            "characterOffset": 99,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(ReadingBookmark.self, from: data)

        XCTAssertEqual(decoded.label, "Legacy")
        XCTAssertEqual(decoded.characterOffset, 99)
        XCTAssertNil(decoded.chapterTitle)
        XCTAssertEqual(decoded.anchorLayout, EPUBAnchor.legacyLayout)

        var blob = Data("{\"version\":1,\"bookmarks\":[".utf8)
        blob.append(data)
        blob.append(contentsOf: "]}".utf8)
        defaults.set(blob, forKey: "bookmarks")
        XCTAssertEqual(makeManager().bookmarks.count, 1, "A legacy element must not be treated as unreadable")
    }

    func testNewBookmarkCarriesCurrentLayoutAndRoundTripsNonDefaultValue() throws {
        var bookmark = ReadingBookmark(
            bookURL: URL(fileURLWithPath: "/books/book.epub"), label: "Here", spineIndex: 0,
            characterOffset: 3)
        XCTAssertEqual(bookmark.anchorLayout, EPUBAnchor.currentLayout)

        bookmark.anchorLayout = 9
        let decoded = try JSONDecoder().decode(ReadingBookmark.self, from: JSONEncoder().encode(bookmark))

        XCTAssertEqual(decoded, bookmark)
        XCTAssertEqual(decoded.anchorLayout, 9)
    }

    private func makeManager() -> BookmarkManager {
        BookmarkManager(defaults: defaults, key: "bookmarks")
    }
}
