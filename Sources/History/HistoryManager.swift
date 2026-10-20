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
    /// Fraction within the saved resource, used when its text layout changes.
    var lastResourceFraction: Double = 0
    /// `EPUBAnchor` layout that `lastCharacterOffset` was saved against. Restore uses it to choose
    /// between the exact offset and `lastResourceFraction`.
    var anchorLayout: Int = EPUBAnchor.currentLayout

    init(url: URL, title: String, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.openedAt = Date()
        self.bookmarkData = bookmarkData
        self.readingProgressPercent = -1
        self.lastSpineIndex = 0
        self.lastCharacterOffset = 0
        self.lastResourceFraction = 0
        self.anchorLayout = EPUBAnchor.currentLayout
    }

    // Swift's synthesized Decodable does NOT fall back to a property's default value
    // for a key that's simply absent from older stored JSON — without this custom
    // decoder, every existing entry from before this patch would fail to decode the
    // first time this ships, and HistoryManager.load()'s guard-let discards the
    // *entire* history array on any decode failure. That's a real
    // "reading history disappeared after the update" bug, not a hypothetical case.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        title = try values.decode(String.self, forKey: .title)
        openedAt = try values.decode(Date.self, forKey: .openedAt)
        bookmarkData = try values.decodeIfPresent(Data.self, forKey: .bookmarkData)
        readingProgressPercent = try values.decode(Int.self, forKey: .readingProgressPercent)
        lastSpineIndex = try values.decodeIfPresent(Int.self, forKey: .lastSpineIndex) ?? 0
        lastCharacterOffset = try values.decodeIfPresent(Int.self, forKey: .lastCharacterOffset) ?? 0
        lastResourceFraction = Locator.clamp(try values.decodeIfPresent(Double.self, forKey: .lastResourceFraction) ?? 0)
        anchorLayout = try values.decodeIfPresent(Int.self, forKey: .anchorLayout) ?? EPUBAnchor.legacyLayout
    }
}

final class HistoryManager {
    static let shared = HistoryManager()
    static let entriesDidChangeNotification = Notification.Name("ReadingHistoryEntriesDidChange")

    private let defaults: UserDefaults
    private let key: String
    /// Ceiling for persisted history. The toolbar popover shows only the 5 most
    /// recent (HistoryViewController.reload); Settings' history pane shows all
    /// stored entries up to this cap.
    private let maxEntries: Int

    private(set) var entries: [HistoryEntry] = []
    /// Stored array elements this build could not decode, as JSON. `save()` re-emits them after the
    /// decoded entries, so they are treated as the oldest items: they count toward `maxEntries` and are
    /// the first to be dropped when the cap is exceeded.
    private var unreadableElements: [Data] = []
    /// Original stored bytes to preserve before the first overwrite, set when the stored blob was not a
    /// readable array. Cleared once preserved (or when the user clears history).
    private var pendingQuarantine: (data: Data, reason: String)?

    init(
        defaults: UserDefaults = .standard,
        key: String = "EPUBReaderHistory",
        maxEntries: Int = 100
    ) {
        self.defaults = defaults
        self.key = key
        self.maxEntries = maxEntries
        load()
    }

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
        let existingResourceFraction = existing?.lastResourceFraction ?? 0
        let existingAnchorLayout = existing?.anchorLayout ?? EPUBAnchor.currentLayout
        entries.removeAll { $0.url == url }

        var entry = HistoryEntry(url: url, title: title, bookmarkData: bookmarkData)
        entry.readingProgressPercent = existingProgress
        entry.lastSpineIndex = existingSpineIndex
        entry.lastCharacterOffset = existingCharacterOffset
        entry.lastResourceFraction = existingResourceFraction
        entry.anchorLayout = existingAnchorLayout
        entries.insert(entry, at: 0)

        enforceCap()
        save()
        notifyEntriesChanged()
    }

    /// Applies `maxEntries` to decoded and unreadable elements together. Unreadable elements sit after
    /// every decoded entry, so they are dropped first.
    private func enforceCap() {
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        let room = max(0, maxEntries - entries.count)
        if unreadableElements.count > room {
            unreadableElements = Array(unreadableElements.prefix(room))
        }
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
    func updatePosition(url: URL, spineIndex: Int, characterOffset: Int, fraction: Double = 0) {
        guard let idx = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[idx].lastSpineIndex = spineIndex
        entries[idx].lastCharacterOffset = max(0, characterOffset)
        entries[idx].lastResourceFraction = Locator.clamp(fraction)
        entries[idx].anchorLayout = EPUBAnchor.currentLayout
        save()
    }

    /// Saved restore position for an entry identified by URL, if any is recorded.
    func savedPosition(for url: URL) -> (spineIndex: Int, characterOffset: Int)? {
        guard let entry = entries.first(where: { $0.url == url }) else { return nil }
        return (entry.lastSpineIndex, entry.lastCharacterOffset)
    }

    func savedLocator(for url: URL) -> Locator? {
        guard let entry = entries.first(where: { $0.url == url }) else { return nil }
        return .flow(
            resource: entry.lastSpineIndex,
            offset: entry.lastCharacterOffset,
            layout: entry.anchorLayout,
            fraction: entry.lastResourceFraction
        )
    }

    /// Return stored reading progress, or -1 if not recorded
    func readingProgress(for entry: HistoryEntry) -> Int {
        return entry.readingProgressPercent
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
        notifyEntriesChanged()
    }

    func clearAll() {
        entries.removeAll()
        // An explicit clear removes everything, including elements this build could not read.
        unreadableElements.removeAll()
        pendingQuarantine = nil
        save()
        notifyEntriesChanged()
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
                if stale,
                    let refreshed = try? resolved.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ),
                    let index = entries.firstIndex(where: { $0.id == entry.id })
                {
                    entries[index].bookmarkData = refreshed
                    save()
                }
                return resolved
            }
        }
        return FileManager.default.fileExists(atPath: entry.url.path) ? entry.url : nil
    }

    private func save() {
        if let pending = pendingQuarantine {
            StorageQuarantine.preserve(pending.data, key: key, defaults: defaults, reason: pending.reason)
            pendingQuarantine = nil
        }
        let encoder = JSONEncoder()
        var elements: [Data] = []
        for entry in entries {
            // Never write a partial list.
            guard let element = try? encoder.encode(entry) else { return }
            elements.append(element)
        }
        elements.append(contentsOf: unreadableElements)

        var output = Data("[".utf8)
        for (index, element) in elements.enumerated() {
            if index > 0 { output.append(0x2C) }
            output.append(element)
        }
        output.append(contentsOf: "]".utf8)
        defaults.set(output, forKey: key)
    }

    private func notifyEntriesChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.entriesDidChangeNotification, object: self)
        }
    }

    /// Decodes element by element in a single `JSONDecoder` pass, so valid entries are never
    /// re-serialized. Raw JSON is only extracted for elements that failed. There is no envelope (and none
    /// is introduced here, to avoid a format migration), so a blob that is not a JSON array is preserved
    /// whole before the first overwrite.
    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        guard let decoded = try? JSONDecoder().decode([LenientEntry].self, from: data) else {
            pendingQuarantine = (data, "stored history is not a readable array")
            return
        }
        entries = decoded.compactMap(\.value)
        guard decoded.contains(where: { $0.value == nil }) else { return }
        let rawElements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
        for (index, element) in decoded.enumerated()
        where element.value == nil && rawElements.indices.contains(index) {
            if let raw = try? JSONSerialization.data(
                withJSONObject: rawElements[index], options: [.fragmentsAllowed])
            {
                unreadableElements.append(raw)
            }
        }
    }

    /// Decodes to `nil` instead of throwing, so one bad element cannot fail the whole array.
    private struct LenientEntry: Decodable {
        let value: HistoryEntry?

        init(from decoder: Decoder) throws {
            value = try? HistoryEntry(from: decoder)
        }
    }
}
