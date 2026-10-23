// BookFormat.swift
// Supported document format definitions and detection (FRAMEWORK L1 Publication)

import Foundation
import UniformTypeIdentifiers

enum BookFormat: String, CaseIterable, Sendable {
    case epub
    case html
    case markdown
    case plainText

    var displayName: String {
        switch self {
        case .epub: return "EPUB Document"
        case .html: return "HTML Document"
        case .markdown: return "Markdown Document"
        case .plainText: return "Plain Text"
        }
    }

    var fileExtensions: Set<String> {
        switch self {
        case .epub:
            return ["epub"]
        case .html:
            return ["html", "htm", "xhtml"]
        case .markdown:
            return ["md", "markdown"]
        case .plainText:
            return ["txt", "text"]
        }
    }

    var contentType: UTType {
        switch self {
        case .epub:
            return UTType("org.idpf.epub-container") ?? .data
        case .html:
            return .html
        case .markdown:
            return UTType("net.daringfireball.markdown") ?? .plainText
        case .plainText:
            return .plainText
        }
    }

    static var supportedContentTypes: [UTType] {
        allCases.map(\.contentType)
    }

    static var supportedExtensions: Set<String> {
        allCases.reduce(into: Set<String>()) { acc, format in
            acc.formUnion(format.fileExtensions)
        }
    }

    static func detect(url: URL) -> BookFormat? {
        guard url.isFileURL else { return nil }
        return detect(pathExtension: url.pathExtension)
    }

    static func detect(pathExtension: String) -> BookFormat? {
        let ext = pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ext.isEmpty else { return nil }
        return allCases.first { $0.fileExtensions.contains(ext) }
    }

    static func isSupported(url: URL) -> Bool {
        detect(url: url) != nil
    }
}
