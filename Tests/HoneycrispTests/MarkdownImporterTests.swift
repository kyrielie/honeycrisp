// MarkdownImporterTests.swift
// Tests for MarkdownImporter (converting Markdown into EPUBPackage)

import XCTest
@testable import Honeycrisp

final class MarkdownImporterTests: XCTestCase {

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

    func testFrontmatterAndHeadings() throws {
        let markdown = """
        ---
        title: "The Rust Odyssey"
        author: "Ferris Crab"
        ---

        # Chapter 1: Memory Safety
        Rust guarantees memory safety without garbage collection.
        Here is some `code` inline, and a [link](https://rust-lang.org).

        ```rust
        fn main() {
            println!("Hello world");
        }
        ```

        ---

        # Chapter 2: Concurrency
        Fearless concurrency is a core tenet.
        > Safety first, speed always.

        - Thread spawning
        - Channels
        - Arc and Mutex
        """

        let pkg = try MarkdownImporter.createPackage(from: markdown, defaultTitle: "Default", destinationDir: tempDir)
        XCTAssertEqual(pkg.title, "The Rust Odyssey")
        XCTAssertEqual(pkg.author, "Ferris Crab")
        XCTAssertEqual(pkg.spineURLs.count, 2)

        let ch1 = try String(contentsOf: pkg.spineURLs[0], encoding: .utf8)
        XCTAssertTrue(ch1.contains("<h1>Chapter 1: Memory Safety</h1>"))
        XCTAssertTrue(ch1.contains("<code>code</code>"))
        XCTAssertTrue(ch1.contains("<a href=\"https://rust-lang.org\">link</a>"))
        XCTAssertTrue(ch1.contains("<pre><code class=\"language-rust\">fn main() {"))
        XCTAssertTrue(ch1.contains("<hr class=\"scene-break\"/>"))

        let ch2 = try String(contentsOf: pkg.spineURLs[1], encoding: .utf8)
        XCTAssertTrue(ch2.contains("<h1>Chapter 2: Concurrency</h1>"))
        XCTAssertTrue(ch2.contains("<blockquote><p>Safety first, speed always.</p></blockquote>"))
        XCTAssertTrue(ch2.contains("<ul>"))
        XCTAssertTrue(ch2.contains("<li>Thread spawning</li>"))
        XCTAssertTrue(ch2.contains("<li>Arc and Mutex</li>"))
    }

    func testInlineFormatting() throws {
        let markdown = """
        # Formatting Test
        This is **bold** text and *italic* text and ***bold italic*** text.
        Here is an image: ![Cat](cat.png)
        """

        let pkg = try MarkdownImporter.createPackage(from: markdown, defaultTitle: "Doc", destinationDir: tempDir)
        let ch1 = try String(contentsOf: pkg.spineURLs[0], encoding: .utf8)
        XCTAssertTrue(ch1.contains("<strong>bold</strong>"))
        XCTAssertTrue(ch1.contains("<em>italic</em>"))
        XCTAssertTrue(ch1.contains("<strong><em>bold italic</em></strong>"))
        XCTAssertTrue(ch1.contains("<img src=\"cat.png\" alt=\"Cat\"/>"))
    }
}
