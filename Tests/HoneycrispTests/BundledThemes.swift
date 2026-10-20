import Foundation
@testable import Honeycrisp

/// Loads the four themes bundled in `Sources/Skins/Bundled` the same way imports do, for tests that
/// used to iterate `SettingsManager.seedThemes`.
enum BundledThemes {
    static let names = ["Original", "Quiet", "Paper", "Fimfiction"]

    static func load() throws -> [ReaderSkin] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("Sources/Skins/Bundled", isDirectory: true)
        return try names.map {
            try SkinLoader.load(directory: root.appendingPathComponent($0 + ".nnwtheme", isDirectory: true))
        }
    }
}
