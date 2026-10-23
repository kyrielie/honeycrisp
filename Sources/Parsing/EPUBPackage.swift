// EPUBPackage.swift
// Publication-level models for EPUB packages and manifests (FRAMEWORK L1 Publication)

import Foundation

struct EPUBPackage {
    let rootFolder: URL
    let spineURLs: [URL]
    let title: String
    let author: String
    let publisher: String?
    let language: String?
    let identifier: String?
    let publicationDate: String?
    let bookDescription: String?
    let subjects: [String]
    let coverURL: URL?
    let manifest: [String: EPUBManifestItem]
    let spine: [EPUBSpineItem]
    let version: String?
    let navigationURL: URL?
    let landmarks: [EPUBLandmark]

    init(
        rootFolder: URL,
        spineURLs: [URL],
        title: String,
        author: String,
        coverURL: URL?,
        manifest: [String: EPUBManifestItem] = [:],
        spine: [EPUBSpineItem]? = nil,
        version: String? = nil,
        navigationURL: URL? = nil,
        landmarks: [EPUBLandmark] = [],
        language: String? = nil,
        publisher: String? = nil,
        identifier: String? = nil,
        publicationDate: String? = nil,
        bookDescription: String? = nil,
        subjects: [String] = []
    ) {
        self.rootFolder = rootFolder
        self.spineURLs = spineURLs
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.manifest = manifest
        self.spine = spine ?? spineURLs.enumerated().map {
            EPUBSpineItem(manifestID: "spine-\($0.offset)", url: $0.element, isLinear: true)
        }
        self.version = version
        self.navigationURL = navigationURL
        self.landmarks = landmarks
        self.language = language
        self.publisher = publisher
        self.identifier = identifier
        self.publicationDate = publicationDate
        self.bookDescription = bookDescription
        self.subjects = subjects
    }
}

struct EPUBManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: Set<String>
    let url: URL
}

struct EPUBSpineItem {
    let manifestID: String
    let url: URL
    let isLinear: Bool
}

struct EPUBLandmark {
    let type: String
    let title: String
    let url: URL
}

struct BookSearchResult {
    let spineIndex: Int
    let characterOffset: Int
    let excerpt: String
}

enum EPUBParseError: Error, LocalizedError {
    case containerNotFound, opfNotFound, malformed, io, drmProtected

    var errorDescription: String? {
        switch self {
        case .containerNotFound: return "Could not find META-INF/container.xml"
        case .opfNotFound:       return "Could not locate the OPF package file"
        case .malformed:         return "EPUB spine is empty or malformed"
        case .io:                return "I/O error while reading EPUB"
        case .drmProtected:      return "This EPUB is protected (DRM) and can't be opened by Honeycrisp."
        }
    }
}
