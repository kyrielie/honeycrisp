// HTMLImporterTests.swift
// Tests for HTMLDocumentImporter (converting single-file HTML into EPUBPackage)

import XCTest
@testable import Honeycrisp

final class HTMLImporterTests: XCTestCase {

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

    func testSplitByArticles() throws {
        let sample = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Chronicles of the Deep</title>
            <meta name="author" content="Arthur Pendelton">
        </head>
        <body>
            <article>
                <h1>Chapter 1: The Descent</h1>
                <p>The submarine reached the abyss.</p>
                <script>alert("malicious");</script>
            </article>
            <article>
                <h1>Chapter 2: The Leviathan</h1>
                <p>Shadows stirred in the dark water.</p>
            </article>
        </body>
        </html>
        """

        let pkg = try HTMLDocumentImporter.createPackage(from: sample, defaultTitle: "Fallback", destinationDir: tempDir)
        XCTAssertEqual(pkg.title, "Chronicles of the Deep")
        XCTAssertEqual(pkg.author, "Arthur Pendelton")
        XCTAssertEqual(pkg.spineURLs.count, 2)

        let ch1 = try String(contentsOf: pkg.spineURLs[0], encoding: .utf8)
        XCTAssertTrue(ch1.contains("<h1>Chapter 1: The Descent</h1>"))
        XCTAssertTrue(ch1.contains("<p>The submarine reached the abyss.</p>"))
        XCTAssertFalse(ch1.contains("<script>"))

        let ch2 = try String(contentsOf: pkg.spineURLs[1], encoding: .utf8)
        XCTAssertTrue(ch2.contains("<h1>Chapter 2: The Leviathan</h1>"))
        XCTAssertTrue(ch2.contains("<p>Shadows stirred in the dark water.</p>"))
    }

    func testSplitByHeadings() throws {
        let sample = """
        <!DOCTYPE html>
        <html>
        <head><title>Anthology</title></head>
        <body>
            <h1>Story One</h1>
            <p>Once upon a time in a faraway forest.</p>
            <h1>Story Two</h1>
            <p>Long ago in a bustling cyber metropolis.</p>
        </body>
        </html>
        """

        let pkg = try HTMLDocumentImporter.createPackage(from: sample, defaultTitle: "Anthology", destinationDir: tempDir)
        XCTAssertEqual(pkg.spineURLs.count, 2)

        let ch1 = try String(contentsOf: pkg.spineURLs[0], encoding: .utf8)
        XCTAssertTrue(ch1.contains("<p>Once upon a time in a faraway forest.</p>"))

        let ch2 = try String(contentsOf: pkg.spineURLs[1], encoding: .utf8)
        XCTAssertTrue(ch2.contains("<p>Long ago in a bustling cyber metropolis.</p>"))
    }

    func testSingleUnstructuredDocument() throws {
        let sample = """
        <!DOCTYPE html>
        <html>
        <head><title>Short Document</title></head>
        <body>
            <p>Single paragraph of text.</p>
        </body>
        </html>
        """

        let pkg = try HTMLDocumentImporter.createPackage(from: sample, defaultTitle: "Short", destinationDir: tempDir)
        XCTAssertEqual(pkg.spineURLs.count, 1)
        XCTAssertEqual(pkg.title, "Short Document")
    }
}
