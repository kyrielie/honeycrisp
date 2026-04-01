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

    init(url: URL, title: String, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.openedAt = Date()
        self.bookmarkData = bookmarkData
        self.readingProgressPercent = -1
    }
}

final class HistoryManager {
    static let shared = HistoryManager()

    private let key = "EPUBReaderHistory"
    private let maxEntries = 50

    private(set) var entries: [HistoryEntry] = []

    private init() { load() }

    func record(url: URL, title: String) {
        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Preserve progress from existing entry if present
        let existingProgress = entries.first(where: { $0.url == url })?.readingProgressPercent ?? -1
        entries.removeAll { $0.url == url }

        var entry = HistoryEntry(url: url, title: title, bookmarkData: bookmarkData)
        entry.readingProgressPercent = existingProgress
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
