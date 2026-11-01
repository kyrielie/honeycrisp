// AO3Metadata.swift
// Data type for AO3 preface metadata read from an EPUB's first spine items (FRAMEWORK L1 Publication).
// Adapted from Ambrosia/Database/AO3Metadata.swift: display-only, so the closed rating, warning and
// category enums are not carried over and unrecognized values are kept as the book spells them.

import Foundation

/// Structured metadata extracted from an AO3 EPUB preface chapter.
/// nil or an empty array means the field was not found in the preface.
/// Not persisted: `ReaderViewController` extracts it once per EPUB open and hands it to Book Info.
struct AO3MetadataRecord: Equatable {
    struct SeriesEntry: Equatable {
        let name: String
        let index: Int
        let ao3ID: String?
    }

    var storyURL: String?
    var workID: String?
    var rating: String?
    var warnings: [String] = []
    var categories: [String] = []
    var fandoms: [String] = []
    var relationships: [String] = []
    var characters: [String] = []
    var additionalTags: [String] = []
    var collections: [String] = []
    var language: String?
    var series: [SeriesEntry] = []
    var wordCount: Int?
    var chapterCurrent: Int?
    var chapterTotal: Int?
    var kudosCount: Int?
    var isComplete = false
    var publishedDate: String?
    var updatedDate: String?
}
