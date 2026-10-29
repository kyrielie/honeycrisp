import Foundation
import XCTest
@testable import Honeycrisp

final class BookmarkSnippetTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BookmarkSnippetTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeManager() -> BookmarkManager {
        BookmarkManager(defaults: defaults, key: "testBookmarks")
    }

    func testBookmarkWithSnippetPersistsAndDecodes() {
        let bookURL = URL(fileURLWithPath: "/books/test.epub")
        let manager = makeManager()
        let snippetText = "The clock struck thirteen, and the cold April wind pierced through the doorway."
        let bookmark = manager.add(
            bookURL: bookURL,
            label: "Chapter 1 · 1",
            spineIndex: 0,
            characterOffset: 45,
            chapterTitle: "Chapter 1",
            snippet: snippetText
        )

        XCTAssertEqual(bookmark.snippet, snippetText)

        let reloadedManager = makeManager()
        let loaded = reloadedManager.bookmarks(for: bookURL).first
        XCTAssertEqual(loaded?.id, bookmark.id)
        XCTAssertEqual(loaded?.snippet, snippetText)
    }

    func testBackwardCompatibilityWithLegacyBookmarkWithoutSnippet() throws {
        // Construct a raw JSON bookmark without the "snippet" key (predates M9)
        let id = UUID()
        let json = """
        {
            "version": 1,
            "bookmarks": [
                {
                    "id": "\(id.uuidString)",
                    "bookPath": "/books/legacy.epub",
                    "label": "Legacy Bookmark",
                    "createdAt": 700000000.0,
                    "spineIndex": 3,
                    "characterOffset": 150,
                    "chapterTitle": "Chapter 4"
                }
            ]
        }
        """
        defaults.set(Data(json.utf8), forKey: "testBookmarks")

        let manager = makeManager()
        let bookmarks = manager.bookmarks(for: URL(fileURLWithPath: "/books/legacy.epub"))
        XCTAssertEqual(bookmarks.count, 1)
        let loaded = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.label, "Legacy Bookmark")
        XCTAssertEqual(loaded.spineIndex, 3)
        XCTAssertEqual(loaded.characterOffset, 150)
        XCTAssertNil(loaded.snippet)
    }
}
