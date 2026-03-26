// HistoryManager.swift
// Persists recently opened EPUB files with open date

import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let openedAt: Date
    var bookmarkData: Data?

    init(url: URL, title: String, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.openedAt = Date()
        self.bookmarkData = bookmarkData
    }
}

final class HistoryManager {
    static let shared = HistoryManager()

    private let key = "EPUBReaderHistory"
    private let maxEntries = 50

    private(set) var entries: [HistoryEntry] = []

    private init() {
        load()
    }

    func record(url: URL, title: String) {
        // Create security-scoped bookmark for sandbox persistence
        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Remove duplicate if present
        entries.removeAll { $0.url == url }

        let entry = HistoryEntry(url: url, title: title, bookmarkData: bookmarkData)
        entries.insert(entry, at: 0)

        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
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
            ) {
                return resolved
            }
        }
        // Fallback to stored URL
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
