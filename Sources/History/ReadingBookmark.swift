import Foundation

struct ReadingBookmark: Codable, Identifiable, Equatable {
    let id: UUID
    let bookPath: String
    var label: String
    let createdAt: Date
    var spineIndex: Int
    var characterOffset: Int
    var chapterTitle: String?

    init(bookURL: URL, label: String, spineIndex: Int, characterOffset: Int, chapterTitle: String? = nil, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.bookPath = Self.normalizedPath(for: bookURL)
        self.label = label
        self.createdAt = createdAt
        self.spineIndex = max(0, spineIndex)
        self.characterOffset = max(0, characterOffset)
        self.chapterTitle = chapterTitle
    }

    static func normalizedPath(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}

final class BookmarkManager {
    static let shared = BookmarkManager()
    private let defaults: UserDefaults
    private let key: String
    private(set) var bookmarks: [ReadingBookmark]

    init(defaults: UserDefaults = .standard, key: String = "HoneycrispReadingBookmarks.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 {
            bookmarks = envelope.bookmarks
        } else {
            bookmarks = []
        }
    }

    func bookmarks(for url: URL) -> [ReadingBookmark] {
        let path = ReadingBookmark.normalizedPath(for: url)
        return bookmarks.filter { $0.bookPath == path }.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func add(bookURL: URL, label: String, spineIndex: Int, characterOffset: Int, chapterTitle: String?) -> ReadingBookmark {
        let item = ReadingBookmark(bookURL: bookURL, label: label, spineIndex: spineIndex, characterOffset: characterOffset, chapterTitle: chapterTitle)
        bookmarks.append(item)
        save()
        return item
    }

    func rename(id: UUID, to label: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].label = label
        save()
    }

    func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    private struct Envelope: Codable {
        let version: Int
        let bookmarks: [ReadingBookmark]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Envelope(version: 1, bookmarks: bookmarks)) else { return }
        defaults.set(data, forKey: key)
    }
}
