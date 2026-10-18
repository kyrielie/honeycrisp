import Foundation

struct ReadingBookmark: Codable, Identifiable, Equatable {
    let id: UUID
    let bookPath: String
    var label: String
    let createdAt: Date
    var spineIndex: Int
    var characterOffset: Int
    var chapterTitle: String?
    /// `EPUBAnchor` layout that `characterOffset` was saved against. Stored for a future change that
    /// alters extraction; nothing reads it yet.
    var anchorLayout: Int

    init(bookURL: URL, label: String, spineIndex: Int, characterOffset: Int, chapterTitle: String? = nil, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.bookPath = Self.normalizedPath(for: bookURL)
        self.label = label
        self.createdAt = createdAt
        self.spineIndex = max(0, spineIndex)
        self.characterOffset = max(0, characterOffset)
        self.chapterTitle = chapterTitle
        self.anchorLayout = EPUBAnchor.currentLayout
    }

    // Synthesized Decodable would fail on stored bookmarks that predate `anchorLayout`, so decode it
    // optionally.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bookPath = try c.decode(String.self, forKey: .bookPath)
        label = try c.decode(String.self, forKey: .label)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        spineIndex = try c.decode(Int.self, forKey: .spineIndex)
        characterOffset = try c.decode(Int.self, forKey: .characterOffset)
        chapterTitle = try c.decodeIfPresent(String.self, forKey: .chapterTitle)
        anchorLayout =
            try c.decodeIfPresent(Int.self, forKey: .anchorLayout) ?? EPUBAnchor.legacyLayout
    }

    static func normalizedPath(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}

final class BookmarkManager {
    static let shared = BookmarkManager()
    /// Envelope version this build writes and fully understands.
    static let supportedVersion = 1

    private let defaults: UserDefaults
    private let key: String
    private(set) var bookmarks: [ReadingBookmark]
    /// Stored array elements this build could not decode, as JSON. `save()` re-emits them so a bad or
    /// newer-format element is never silently dropped.
    private var unreadableElements: [Data] = []
    /// Original stored bytes to preserve before the first overwrite, set when the stored blob was not
    /// a readable envelope of the supported version. Cleared once preserved.
    private var pendingQuarantine: (data: Data, reason: String)?

    init(defaults: UserDefaults = .standard, key: String = "HoneycrispReadingBookmarks.v1") {
        self.defaults = defaults
        self.key = key
        bookmarks = []
        if let data = defaults.data(forKey: key) {
            loadStoredData(data)
        }
    }

    /// Decodes element by element. Elements that decode are kept; the rest are retained as raw JSON.
    /// Decoding is a single `JSONDecoder` pass, so valid elements are never re-serialized (no loss of
    /// `Date` precision). Raw JSON is only extracted for the elements that failed.
    private func loadStoredData(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            pendingQuarantine = (data, "stored bookmarks are not a readable envelope")
            return
        }
        bookmarks = envelope.elements.compactMap(\.value)
        if envelope.elements.contains(where: { $0.value == nil }) {
            let rawElements = Self.rawElements(in: data)
            for (index, element) in envelope.elements.enumerated()
            where element.value == nil && rawElements.indices.contains(index) {
                if let raw = try? JSONSerialization.data(
                    withJSONObject: rawElements[index], options: [.fragmentsAllowed]) {
                    unreadableElements.append(raw)
                }
            }
        }
        if envelope.version != Self.supportedVersion {
            pendingQuarantine = (data, "stored bookmarks have envelope version \(envelope.version)")
        }
    }

    private static func rawElements(in data: Data) -> [Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let elements = root["bookmarks"] as? [Any]
        else { return [] }
        return elements
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

    private struct Envelope: Decodable {
        let version: Int
        let elements: [LenientBookmark]

        private enum CodingKeys: String, CodingKey {
            case version
            case elements = "bookmarks"
        }
    }

    /// Decodes to `nil` instead of throwing, so one bad element cannot fail the whole array.
    private struct LenientBookmark: Decodable {
        let value: ReadingBookmark?

        init(from decoder: Decoder) throws {
            value = try? ReadingBookmark(from: decoder)
        }
    }

    private func save() {
        if let pending = pendingQuarantine {
            StorageQuarantine.preserve(pending.data, key: key, defaults: defaults, reason: pending.reason)
            pendingQuarantine = nil
        }
        let encoder = JSONEncoder()
        var elements: [Data] = []
        for bookmark in bookmarks {
            // Never write a partial list.
            guard let element = try? encoder.encode(bookmark) else { return }
            elements.append(element)
        }
        elements.append(contentsOf: unreadableElements)

        var output = Data("{\"version\":\(Self.supportedVersion),\"bookmarks\":[".utf8)
        for (index, element) in elements.enumerated() {
            if index > 0 { output.append(0x2C) }
            output.append(element)
        }
        output.append(contentsOf: "]}".utf8)
        defaults.set(output, forKey: key)
    }
}
