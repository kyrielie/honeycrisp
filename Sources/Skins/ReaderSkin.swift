import Foundation

struct SkinColorTokens: Equatable {
    var background: String
    var ink: String
    var link: String
}

struct ReaderSkin: Equatable, Identifiable {
    let id: String
    var name: String
    var creator: String?
    var version: String?
    var css: String
    var template: String
    var light: SkinColorTokens?
    var dark: SkinColorTokens?
    var usesDefaultColors: Bool
    var lowContrast: Bool
    var fontImports: [String]
    /// NNW `Family` plist key: a grouping name for a later grouped picker. Never a CSS font stack.
    var familyGroup: String?
    var familyVariant: String?
    var license: String?
}

enum SkinImportError: Error, LocalizedError {
    case invalidBundle(String)
    case archiveTooLarge
    case unsafeArchiveEntry(String)
    case duplicateIdentifier(String)
    case io

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let reason): return reason
        case .archiveTooLarge: return "The skin archive exceeds the allowed size."
        case .unsafeArchiveEntry(let path): return "The skin archive contains an unsafe entry: \(path)"
        case .duplicateIdentifier(let name): return "A skin with the identifier \(name) is already installed."
        case .io: return "The skin could not be read or installed."
        }
    }
}

