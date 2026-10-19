import Foundation
import ZIPFoundation

final class SkinStore {
    static let shared = SkinStore()
    private(set) var skins: [ReaderSkin] = []
    private let fileManager: FileManager
    private let bundledURL: URL?
    private let installedURL: URL

    init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        self.bundledURL = bundle.resourceURL?.appendingPathComponent("Bundled", isDirectory: true)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.installedURL = support.appendingPathComponent("Honeycrisp/Skins", isDirectory: true)
        reload()
    }

    func reload() {
        var result: [String: ReaderSkin] = [:]
        for root in [bundledURL, installedURL].compactMap({ $0 }) {
            guard let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for child in children where child.pathExtension.lowercased() == "nnwtheme" {
                if let skin = try? SkinLoader.load(directory: child) { result[skin.id] = skin }
            }
        }
        skins = result.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func skin(id: String?) -> ReaderSkin? {
        guard let id else { return nil }
        return skins.first { $0.id == id }
    }

    func importSkin(from source: URL, replacingExisting: Bool = false) throws -> ReaderSkin {
        let skin = try SkinLoader.load(directory: source)
        if skin.id.hasPrefix("com.honeycrisp.") { throw SkinImportError.invalidBundle("This identifier is reserved for a built-in Honeycrisp skin.") }
        let existing = self.skin(id: skin.id)
        if existing != nil && !replacingExisting { throw SkinImportError.duplicateIdentifier(skin.name) }
        try fileManager.createDirectory(at: installedURL, withIntermediateDirectories: true)
        let destination = installedURL.appendingPathComponent(safeDirectoryName(skin.id), isDirectory: true)
            .appendingPathExtension("nnwtheme")
        let staging = installedURL.appendingPathComponent(".\(UUID().uuidString).nnwtheme", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let files = try SkinLoader.validatedFiles(in: source)
        for (sourceFile, name) in [(files.info, "Info.plist"), (files.css, "stylesheet.css"), (files.template, "template.html")] {
            try fileManager.copyItem(at: sourceFile, to: staging.appendingPathComponent(name))
        }
        if let license = files.license { try fileManager.copyItem(at: license, to: staging.appendingPathComponent("License.md")) }
        let replacing = fileManager.fileExists(atPath: destination.path)
        let backup = installedURL.appendingPathComponent(".\(UUID().uuidString).backup", isDirectory: true)
        if replacing { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: staging, to: destination)
            if replacing { try fileManager.removeItem(at: backup) }
        } catch {
            if replacing, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        reload()
        return skin
    }

    func importSkin(zipURL: URL, replacingExisting: Bool = false) throws -> ReaderSkin {
        guard let archive = Archive(url: zipURL, accessMode: .read) else { throw SkinImportError.io }
        let entries = Array(archive)
        let compressed = entries.reduce(UInt64(0)) { $0 + $1.compressedSize }
        let expanded = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        guard compressed <= 10_000_000, expanded <= 50 * 1024 * 1024 else { throw SkinImportError.archiveTooLarge }
        guard entries.allSatisfy({ $0.type != .symlink && safeArchivePath($0.path) }) else {
            throw SkinImportError.unsafeArchiveEntry(entries.first(where: { $0.type == .symlink || !safeArchivePath($0.path) })?.path ?? "unknown")
        }
        let wanted = ["Info.plist", "stylesheet.css", "template.html"]
        let candidates = Set(entries.flatMap { entry -> [String] in
            let path = entry.path.split(separator: "/").map(String.init)
            guard let last = path.last, wanted.contains(last) else { return [] }
            return [path.dropLast().joined(separator: "/")]
        })
        guard candidates.count == 1, let prefix = candidates.first else {
            throw SkinImportError.invalidBundle("The archive must contain one skin bundle.")
        }
        var content: [String: Data] = [:]
        for name in wanted + ["License.md", "LICENSE", "NOTICE"] {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard let entry = archive[path], entry.type == .file else { continue }
            var data = Data()
            _ = try archive.extract(entry, consumer: { data.append($0) })
            content[name] = data
        }
        guard let info = content["Info.plist"], let css = content["stylesheet.css"], let template = content["template.html"] else {
            throw SkinImportError.invalidBundle("The archive is missing a required skin file.")
        }
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("SkinImport-\(UUID().uuidString).nnwtheme", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        try info.write(to: temporary.appendingPathComponent("Info.plist"))
        try css.write(to: temporary.appendingPathComponent("stylesheet.css"))
        try template.write(to: temporary.appendingPathComponent("template.html"))
        for license in ["License.md", "LICENSE", "NOTICE"] {
            if let data = content[license] { try data.write(to: temporary.appendingPathComponent(license)); break }
        }
        return try importSkin(from: temporary, replacingExisting: replacingExisting)
    }

    private func safeDirectoryName(_ id: String) -> String {
        let value = id.precomposedStringWithCanonicalMapping
        return value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
    }

    private func safeArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}

