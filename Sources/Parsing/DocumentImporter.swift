// DocumentImporter.swift
// Unified entrypoint for importing readable documents into Honeycrisp

import Foundation

enum DocumentImporterError: LocalizedError, Equatable {
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext)"
        }
    }
}

/// Unified entrypoint for importing readable documents into an EPUBPackage.
///
/// Dispatches to the format-specific parser/importer based on file format detection.
/// Layer 2 parsing/content service (pure Foundation, no WebKit or AppKit).
enum DocumentImporter {

    /// Imports a document from `sourceURL` into `destinationDirectory`, returning a parsed `EPUBPackage`.
    ///
    /// - Parameters:
    ///   - sourceURL: The source file URL (EPUB, TXT, HTML, MD, etc.).
    ///   - destinationDirectory: The folder where files should be extracted or synthesized.
    /// - Returns: A fully populated `EPUBPackage`.
    /// - Throws: `DocumentImporterError` or format-specific parsing errors if import fails.
    static func importDocument(at sourceURL: URL, to destinationDirectory: URL) throws -> EPUBPackage {
        guard let format = BookFormat.detect(url: sourceURL) else {
            throw DocumentImporterError.unsupportedFormat(sourceURL.pathExtension)
        }
        switch format {
        case .epub:
            let parser = EPUBParser()
            let extracted = try parser.unpackEPUB(at: sourceURL, to: destinationDirectory)
            return try parser.parsePackage(at: extracted)
        case .plainText:
            return try PlainTextImporter.importDocument(at: sourceURL, to: destinationDirectory)
        case .html:
            return try HTMLDocumentImporter.importDocument(at: sourceURL, to: destinationDirectory)
        case .markdown:
            return try MarkdownImporter.importDocument(at: sourceURL, to: destinationDirectory)
        }
    }
}
