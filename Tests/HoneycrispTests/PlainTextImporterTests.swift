// PlainTextImporterTests.swift
// Tests for PlainTextImporter (converting .txt into EPUBPackage)

import XCTest
@testable import Honeycrisp

final class PlainTextImporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testMetadataAndChapterSplitting() throws {
        let sample = """
        Title: The Starlight Voyage
        Author: Jane Doe

        Chapter 1: The Beginning
        It was a dark and stormy night.
        The ship sailed on through the mist.

        ---

        A sudden light appeared on the horizon.

        Chapter 2: The Discovery
        Dawn broke across the quiet sea.
        > We have found it, whispered the captain.
        """

        let pkg = try PlainTextImporter.createPackage(from: sample, defaultTitle: "Fallback", destinationDir: tempDir)
        XCTAssertEqual(pkg.title, "The Starlight Voyage")
        XCTAssertEqual(pkg.author, "Jane Doe")
        XCTAssertEqual(pkg.spineURLs.count, 2)
        XCTAssertEqual(pkg.spine.count, 2)

        let ch1 = try String(contentsOf: pkg.spineURLs[0], encoding: .utf8)
        XCTAssertTrue(ch1.contains("<h1>Chapter 1: The Beginning</h1>"))
        XCTAssertTrue(ch1.contains("<hr class=\"scene-break\"/>"))
        XCTAssertTrue(ch1.contains("<p>It was a dark and stormy night. The ship sailed on through the mist.</p>"))

        let ch2 = try String(contentsOf: pkg.spineURLs[1], encoding: .utf8)
        XCTAssertTrue(ch2.contains("<h1>Chapter 2: The Discovery</h1>"))
        XCTAssertTrue(ch2.contains("<blockquote><p>We have found it, whispered the captain.</p></blockquote>"))
    }

    func testNumberedHeadingPatterns() throws {
        let sample = """
        1. A New Dawn
        First paragraph here.

        2. The Journey
        Second paragraph here.
        """

        let pkg = try PlainTextImporter.createPackage(from: sample, defaultTitle: "Novel", destinationDir: tempDir)
        XCTAssertEqual(pkg.spineURLs.count, 2)
        let ch1 = try String(contentsOf: pkg.spineURLs[0], encoding: .utf8)
        XCTAssertTrue(ch1.contains("<h1>1. A New Dawn</h1>"))
    }

    func testUnstructuredTextChunking() throws {
        // Generate a text with many paragraphs exceeding 25,000 characters without explicit chapter headings
        var paragraphs: [String] = []
        for i in 1...60 {
            paragraphs.append("Paragraph \(i): " + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20))
        }
        let sample = paragraphs.joined(separator: "\n\n")

        let pkg = try PlainTextImporter.createPackage(from: sample, defaultTitle: "LongEssay", destinationDir: tempDir)
        XCTAssertGreaterThan(pkg.spineURLs.count, 1)
        XCTAssertEqual(pkg.title, "LongEssay")
    }
}
