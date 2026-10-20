import Foundation

enum SkinLoader {
    static func load(directory: URL) throws -> ReaderSkin {
        let files = try validatedFiles(in: directory)
        let plistData = try Data(contentsOf: files.info)
        guard plistData.count <= SkinValidator.maxPlistBytes,
              let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        else { throw SkinImportError.invalidBundle("The skin Info.plist is invalid or too large.") }
        let id = (plist["ThemeIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty, id.utf8.count <= 256 else {
            throw SkinImportError.invalidBundle("Info.plist must contain a ThemeIdentifier.")
        }
        let css = try String(contentsOf: files.css, encoding: .utf8)
        let sourceTemplate = try String(contentsOf: files.template, encoding: .utf8)
        let template = SkinTemplate.sanitize(sourceTemplate)
        let validation = try SkinValidator.validate(css: css, template: template)
        let name = ((plist["Name"] as? String)?.precomposedStringWithCanonicalMapping).flatMap { $0.isEmpty ? nil : $0 }
            ?? directory.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        return ReaderSkin(id: id, name: name, creator: plist["CreatorName"] as? String, version: plist["Version"] as? String,
                          css: validation.css, template: template, light: validation.light, dark: validation.dark,
                          usesDefaultColors: validation.usesDefaultColors, lowContrast: validation.lowContrast,
                          fontImports: validation.fontImports, familyGroup: sanitizedGroupName(plist["Family"] as? String),
                          familyVariant: plist["FamilyVariant"] as? String,
                          license: files.license.flatMap { try? String(contentsOf: $0, encoding: .utf8) })
    }

    /// `Family` is display-only metadata. Strip control characters, trim, and cap the length so it is
    /// safe to show in UI; it is never interpolated into CSS.
    static func sanitizedGroupName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(128))
    }

    static func validatedFiles(in directory: URL) throws -> (info: URL, css: URL, template: URL, license: URL?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkinImportError.invalidBundle("Choose a .nnwtheme folder.")
        }
        let resolved = directory.standardizedFileURL
        func safeFile(_ name: String) -> URL? {
            let url = resolved.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url
        }
        guard let info = safeFile("Info.plist"), let css = safeFile("stylesheet.css"), let template = safeFile("template.html") else {
            throw SkinImportError.invalidBundle("A skin folder needs Info.plist, stylesheet.css and template.html files.")
        }
        return (info, css, template, safeFile("License.md") ?? safeFile("LICENSE") ?? safeFile("NOTICE"))
    }
}

