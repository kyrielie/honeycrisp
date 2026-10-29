import Foundation
import os

/// Persistence engine managing on-disk theme files in `<Application Support>/Honeycrisp/Themes/`.
/// Conforms to Decision R19 / Milestone M2.1:
/// - One file per theme: `<slug>.honeycrisp-theme.json`
/// - Owns the in-memory cache (`themes`)
/// - Handles atomic writes, slug collision disambiguation, and debounced flushing
/// - Performs external change detection on app activation and appearance tab opening
/// - Degrades gracefully to in-memory mode if the directory is unwritable
final class ThemeStore {
    static let shared = ThemeStore()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Honeycrisp",
        category: "ThemeStore"
    )

    let directoryURL: URL
    private let fileManager: FileManager
    private let seedThemes: [Theme]
    private let validSeedKeys: Set<String>

    private(set) var isReadOnly: Bool = false
    private var cachedThemes: [Theme] = []
    private var themeFileMap: [UUID: URL] = [:]
    private var pendingWrites: [UUID: Theme] = [:]
    private var pendingDeletions: Set<UUID> = []
    private var debounceTimer: Timer?
    private let lock = NSLock()

    static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("Honeycrisp/Themes", isDirectory: true)
    }

    init(
        directoryURL: URL = ThemeStore.defaultDirectoryURL,
        fileManager: FileManager = .default,
        seedThemes: [Theme] = SettingsManager.seedThemes
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.seedThemes = seedThemes
        self.validSeedKeys = Set(seedThemes.compactMap(\.seedKey))
        setupDirectory()
        loadThemesFromDisk()
    }

    deinit {
        debounceTimer?.invalidate()
    }

    // MARK: - Directory Setup

    private func setupDirectory() {
        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }
            // Check write permission
            let testFileURL = directoryURL.appendingPathComponent(".perm_test_\(UUID().uuidString)")
            try "test".write(to: testFileURL, atomically: true, encoding: .utf8)
            try? fileManager.removeItem(at: testFileURL)
            isReadOnly = false
        } catch {
            Self.log.error("Failed to prepare themes directory at \(self.directoryURL.path): \(error.localizedDescription)")
            isReadOnly = true
        }
    }

    // MARK: - Cache Access & Rescan

    var themes: [Theme] {
        lock.lock()
        defer { lock.unlock() }
        return cachedThemes
    }

    /// Reloads themes from disk. If on-disk themes differ from the in-memory cache,
    /// updates the cache and returns true.
    @discardableResult
    func rescanIfChanged() -> Bool {
        flushPendingWrites()

        lock.lock()
        let oldThemes = cachedThemes
        lock.unlock()

        loadThemesFromDisk()

        lock.lock()
        let changed = (cachedThemes != oldThemes)
        lock.unlock()

        return changed
    }

    // MARK: - Loading

    private func loadThemesFromDisk() {
        guard !isReadOnly else {
            lock.lock()
            if cachedThemes.isEmpty {
                cachedThemes = seedThemes
            }
            lock.unlock()
            return
        }

        var (loadedThemes, loadedFileMap) = readThemeFiles()
        ensureSeeds(in: &loadedThemes, fileMap: &loadedFileMap)

        let sortedThemes = sortThemes(loadedThemes)

        lock.lock()
        cachedThemes = sortedThemes
        themeFileMap = loadedFileMap
        lock.unlock()
    }

    private func readThemeFiles() -> ([Theme], [UUID: URL]) {
        var loadedThemes: [Theme] = []
        var loadedFileMap: [UUID: URL] = [:]
        var seenIDs: Set<UUID> = []

        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.log.error("Could not list themes directory: \(error.localizedDescription)")
            items = []
        }

        let themeFiles = items.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(ThemeFileCodec.fileExtension) }

        for fileURL in themeFiles {
            do {
                let data = try Data(contentsOf: fileURL)
                let theme = try ThemeFileCodec.decode(data: data, validSeedKeys: validSeedKeys)
                if seenIDs.contains(theme.id) {
                    Self.log.warning("Duplicate theme id \(theme.id) in \(fileURL.lastPathComponent); skipping duplicate")
                    continue
                }
                seenIDs.insert(theme.id)
                loadedThemes.append(theme)
                loadedFileMap[theme.id] = fileURL
            } catch {
                Self.log.warning("Skipping unreadable or invalid theme file \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (loadedThemes, loadedFileMap)
    }

    private func ensureSeeds(in loadedThemes: inout [Theme], fileMap: inout [UUID: URL]) {
        var seedsToAdd: [Theme] = []
        for seed in seedThemes {
            if let existingIndex = loadedThemes.firstIndex(where: {
                $0.seedKey == seed.seedKey || ($0.isDefault && $0.name == seed.name)
            }) {
                var currentSeed = loadedThemes[existingIndex]
                currentSeed.isDefault = true
                currentSeed.seedKey = seed.seedKey
                loadedThemes[existingIndex] = currentSeed
            } else {
                seedsToAdd.append(seed)
            }
        }

        for missingSeed in seedsToAdd {
            loadedThemes.append(missingSeed)
            if let writtenURL = writeThemeAtomically(missingSeed) {
                fileMap[missingSeed.id] = writtenURL
            }
        }
    }

    private func sortThemes(_ list: [Theme]) -> [Theme] {
        var seeds: [Theme] = []
        var custom: [Theme] = []

        for seed in seedThemes {
            if let found = list.first(where: { $0.seedKey == seed.seedKey || ($0.isDefault && $0.name == seed.name) }) {
                seeds.append(found)
            }
        }
        for item in list where !seeds.contains(where: { $0.id == item.id }) {
            custom.append(item)
        }
        custom.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return seeds + custom
    }

    // MARK: - Mutation & Saving

    /// Updates the in-memory cache and schedules debounced file writes.
    func setThemes(_ newThemes: [Theme], debounce: Bool = true) {
        lock.lock()
        let oldThemes = cachedThemes
        cachedThemes = newThemes

        let oldIDs = Set(oldThemes.map(\.id))
        let newIDs = Set(newThemes.map(\.id))

        // Deleted themes (cannot delete seeds)
        let deletedIDs = oldIDs.subtracting(newIDs).filter { id in
            !(oldThemes.first(where: { $0.id == id })?.isDefault ?? false)
        }
        for delID in deletedIDs {
            pendingDeletions.insert(delID)
            pendingWrites.removeValue(forKey: delID)
        }

        // Added or updated themes
        for theme in newThemes {
            if let old = oldThemes.first(where: { $0.id == theme.id }), old == theme {
                continue // Unchanged
            }
            pendingWrites[theme.id] = theme
            pendingDeletions.remove(theme.id)
        }
        lock.unlock()

        if debounce && !isReadOnly {
            scheduleDebouncedFlush()
        } else {
            flushPendingWrites()
        }
    }

    /// Immediately flushes all queued writes and deletions to disk.
    func flushPendingWrites() {
        lock.lock()
        debounceTimer?.invalidate()
        debounceTimer = nil

        let writes = pendingWrites
        let deletions = pendingDeletions
        pendingWrites.removeAll()
        pendingDeletions.removeAll()
        lock.unlock()

        guard !isReadOnly else { return }

        // Perform deletions
        for id in deletions {
            lock.lock()
            let fileURL = themeFileMap.removeValue(forKey: id)
            lock.unlock()
            if let fileURL {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        // Perform writes
        for (_, theme) in writes {
            if let writtenURL = writeThemeAtomically(theme) {
                lock.lock()
                themeFileMap[theme.id] = writtenURL
                lock.unlock()
            }
        }
    }

    private func scheduleDebouncedFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                self?.flushPendingWrites()
            }
        }
    }

    /// Atomically writes a theme file, resolving collisions and updating maps.
    @discardableResult
    private func writeThemeAtomically(_ theme: Theme) -> URL? {
        guard !isReadOnly else { return nil }

        let data: Data
        do {
            data = try ThemeFileCodec.encode(theme: theme)
        } catch {
            Self.log.error("Failed to encode theme '\(theme.name)': \(error.localizedDescription)")
            return nil
        }

        lock.lock()
        let oldURL = themeFileMap[theme.id]
        lock.unlock()

        let baseSlug = ThemeFileCodec.slug(for: theme.name)
        let targetURL = resolveAvailableURL(forSlug: baseSlug, themeID: theme.id)

        let tempURL = directoryURL.appendingPathComponent(".tmp_\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: targetURL.path) && targetURL.standardized != tempURL.standardized {
                _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: targetURL)
            }

            // If the slug changed and old file exists, remove the old file
            if let oldURL, oldURL.standardized != targetURL.standardized, fileManager.fileExists(atPath: oldURL.path) {
                try? fileManager.removeItem(at: oldURL)
            }
            return targetURL
        } catch {
            Self.log.error("Failed to write theme '\(theme.name)' to \(targetURL.path): \(error.localizedDescription)")
            try? fileManager.removeItem(at: tempURL)
            return nil
        }
    }

    /// Resolves an unused filename for a slug. If the file already belongs to `themeID`, reuses it.
    private func resolveAvailableURL(forSlug slug: String, themeID: UUID) -> URL {
        var collision = 1
        while true {
            let filename = ThemeFileCodec.filename(for: slug, collisionIndex: collision)
            let candidate = directoryURL.appendingPathComponent(filename)

            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }

            // If file already exists, check if it belongs to this same themeID
            if let existingData = try? Data(contentsOf: candidate),
               let existingTheme = try? ThemeFileCodec.decode(data: existingData, validSeedKeys: validSeedKeys),
               existingTheme.id == themeID {
                return candidate
            }

            collision += 1
        }
    }
}
