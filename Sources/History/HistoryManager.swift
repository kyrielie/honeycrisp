// HistoryManager.swift
// Persists recently opened EPUB files with open date and reading progress

import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let openedAt: Date
    var bookmarkData: Data?
    /// Last known reading progress (0-100). -1 means unknown.
    var readingProgressPercent: Int
    /// Spine item the reader was on when last saved. Currently always 0 in scroll
    /// mode (the whole book is one merged document); meaningful once paginated mode
    /// loads a single spine item at a time.
    var lastSpineIndex: Int = 0
    /// Exact reading position: UTF-16 code units, counted via a
    /// TreeWalker(NodeFilter.SHOW_TEXT) over document.body. Precise restore target,
    /// separate from readingProgressPercent (which stays exactly as-is and keeps
    /// driving the "N% read" history-list label).
    var lastCharacterOffset: Int = 0

    init(url: URL, title: String, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.openedAt = Date()
        self.bookmarkData = bookmarkData
        self.readingProgressPercent = -1
        self.lastSpineIndex = 0
        self.lastCharacterOffset = 0
    }

    // Swift's synthesized Decodable does NOT fall back to a property's default value
    // for a key that's simply absent from older stored JSON — without this custom
    // decoder, every existing entry from before this patch would fail to decode the
    // first time this ships, and HistoryManager.load()'s guard-let discards the
    // *entire* history array on any decode failure. That's a real
    // "reading history disappeared after the update" bug, not a hypothetical case.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        openedAt = try c.decode(Date.self, forKey: .openedAt)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        readingProgressPercent = try c.decode(Int.self, forKey: .readingProgressPercent)
        lastSpineIndex = try c.decodeIfPresent(Int.self, forKey: .lastSpineIndex) ?? 0
        lastCharacterOffset = try c.decodeIfPresent(Int.self, forKey: .lastCharacterOffset) ?? 0
    }
}

final class HistoryManager {
    static let shared = HistoryManager()

    private let key = "EPUBReaderHistory"
    /// Ceiling for persisted history. The toolbar popover shows only the 5 most
    /// recent (HistoryViewController.reload); Settings' history pane shows all
    /// stored entries up to this cap.
    private let maxEntries = 100

    private(set) var entries: [HistoryEntry] = []

    private init() { load() }

    func record(url: URL, title: String) {
        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Preserve progress AND saved restore position from the existing entry,
        // if present. record() runs on every open, before the caller has a
        // chance to read savedPosition(for:) — previously this rebuilt a brand
        // new HistoryEntry here (which defaults lastSpineIndex/lastCharacterOffset
        // to 0), so by the time ReaderViewController.loadEPUB went to look up
        // the saved position it always read back (0, 0) and every open silently
        // landed at the start of the book. Carrying these two fields forward the
        // same way readingProgressPercent already was is what makes "resume
        // where you left off" actually work.
        let existing = entries.first(where: { $0.url == url })
        let existingProgress = existing?.readingProgressPercent ?? -1
        let existingSpineIndex = existing?.lastSpineIndex ?? 0
        let existingCharacterOffset = existing?.lastCharacterOffset ?? 0
        entries.removeAll { $0.url == url }

        var entry = HistoryEntry(url: url, title: title, bookmarkData: bookmarkData)
        entry.readingProgressPercent = existingProgress
        entry.lastSpineIndex = existingSpineIndex
        entry.lastCharacterOffset = existingCharacterOffset
        entries.insert(entry, at: 0)

        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    /// Update reading progress for an entry identified by URL
    func updateProgress(url: URL, percent: Int) {
        guard let idx = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[idx].readingProgressPercent = min(100, max(0, percent))
        save()
    }

    /// Update the precise restore position (spine item + UTF-16 character offset)
    /// for an entry identified by URL. Parallel to updateProgress, but doesn't touch
    /// readingProgressPercent — that field keeps being computed the way it already is.
    func updatePosition(url: URL, spineIndex: Int, characterOffset: Int) {
        guard let idx = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[idx].lastSpineIndex = spineIndex
        entries[idx].lastCharacterOffset = max(0, characterOffset)
        save()
    }

    /// Saved restore position for an entry identified by URL, if any is recorded.
    func savedPosition(for url: URL) -> (spineIndex: Int, characterOffset: Int)? {
        guard let entry = entries.first(where: { $0.url == url }) else { return nil }
        return (entry.lastSpineIndex, entry.lastCharacterOffset)
    }

    /// Return stored reading progress, or -1 if not recorded
    func readingProgress(for entry: HistoryEntry) -> Int {
        return entry.readingProgressPercent
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func resolveURL(for entry: HistoryEntry) -> URL? {
        if let bookmark = entry.bookmarkData {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) { return resolved }
        }
        return FileManager.default.fileExists(atPath: entry.url.path) ? entry.url : nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }
}
