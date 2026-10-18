import Foundation
import os

/// Keeps a bounded number of raw copies of stored data that this build could not fully read, so a
/// later write never destroys the only copy. Used by `BookmarkManager` and `HistoryManager`.
///
/// Copies live in the same `UserDefaults` domain under `<key>.quarantine.<unix-seconds>`. UserDefaults is
/// not meant for bulk data, so only the newest `maxCopies` are kept.
enum StorageQuarantine {
    static let maxCopies = 3

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Honeycrisp",
        category: "StorageQuarantine"
    )

    static func quarantineKey(for key: String, stamp: Int) -> String {
        "\(key).quarantine.\(stamp)"
    }

    /// Existing quarantine copies for `key`, oldest first.
    static func quarantinedKeys(for key: String, defaults: UserDefaults) -> [(key: String, stamp: Int)] {
        let prefix = "\(key).quarantine."
        var found: [(key: String, stamp: Int)] = []
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) {
            if let stamp = Int(name.dropFirst(prefix.count)) {
                found.append((key: name, stamp: stamp))
            }
        }
        return found.sorted { $0.stamp < $1.stamp }
    }

    /// Writes `raw` to a new quarantine key and prunes older copies beyond `maxCopies`.
    /// The new stamp is always greater than any existing one, so a copy is never overwritten and the
    /// newest copy is never the one pruned, even if the clock moved backwards.
    @discardableResult
    static func preserve(
        _ raw: Data,
        key: String,
        defaults: UserDefaults,
        reason: String,
        now: Date = Date()
    ) -> String {
        let existing = quarantinedKeys(for: key, defaults: defaults)
        let stamp = max(Int(now.timeIntervalSince1970), (existing.last?.stamp ?? -1) + 1)
        let name = quarantineKey(for: key, stamp: stamp)
        defaults.set(raw, forKey: name)
        log.error("Preserved \(raw.count) bytes under \(name, privacy: .public): \(reason, privacy: .public)")

        for old in quarantinedKeys(for: key, defaults: defaults).dropLast(maxCopies) {
            defaults.removeObject(forKey: old.key)
        }
        return name
    }
}
