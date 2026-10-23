// BookFormatTests.swift
// Tests for document format detection and UTType mapping

import XCTest
import UniformTypeIdentifiers
@testable import Honeycrisp

final class BookFormatTests: XCTestCase {

    func testDetectEPUB() {
        XCTAssertEqual(BookFormat.detect(pathExtension: "epub"), .epub)
        XCTAssertEqual(BookFormat.detect(pathExtension: "EPUB"), .epub)
        let fileURL = URL(fileURLWithPath: "/tmp/book.epub")
        XCTAssertEqual(BookFormat.detect(url: fileURL), .epub)
        XCTAssertTrue(BookFormat.isSupported(url: fileURL))
    }

    func testDetectHTML() {
        XCTAssertEqual(BookFormat.detect(pathExtension: "html"), .html)
        XCTAssertEqual(BookFormat.detect(pathExtension: "htm"), .html)
        XCTAssertEqual(BookFormat.detect(pathExtension: "xhtml"), .html)
        XCTAssertEqual(BookFormat.detect(pathExtension: "HTML"), .html)
        let fileURL = URL(fileURLWithPath: "/tmp/story.xhtml")
        XCTAssertEqual(BookFormat.detect(url: fileURL), .html)
        XCTAssertTrue(BookFormat.isSupported(url: fileURL))
    }

    func testDetectMarkdown() {
        XCTAssertEqual(BookFormat.detect(pathExtension: "md"), .markdown)
        XCTAssertEqual(BookFormat.detect(pathExtension: "markdown"), .markdown)
        XCTAssertEqual(BookFormat.detect(pathExtension: "MD"), .markdown)
        let fileURL = URL(fileURLWithPath: "/tmp/notes.md")
        XCTAssertEqual(BookFormat.detect(url: fileURL), .markdown)
        XCTAssertTrue(BookFormat.isSupported(url: fileURL))
    }

    func testDetectPlainText() {
        XCTAssertEqual(BookFormat.detect(pathExtension: "txt"), .plainText)
        XCTAssertEqual(BookFormat.detect(pathExtension: "text"), .plainText)
        XCTAssertEqual(BookFormat.detect(pathExtension: "TXT"), .plainText)
        let fileURL = URL(fileURLWithPath: "/tmp/novel.txt")
        XCTAssertEqual(BookFormat.detect(url: fileURL), .plainText)
        XCTAssertTrue(BookFormat.isSupported(url: fileURL))
    }

    func testUnsupportedFormats() {
        XCTAssertNil(BookFormat.detect(pathExtension: "pdf"))
        XCTAssertNil(BookFormat.detect(pathExtension: "cbz"))
        XCTAssertNil(BookFormat.detect(pathExtension: "mobi"))
        XCTAssertNil(BookFormat.detect(pathExtension: ""))
        let unsupportedURL = URL(fileURLWithPath: "/tmp/document.pdf")
        XCTAssertNil(BookFormat.detect(url: unsupportedURL))
        XCTAssertFalse(BookFormat.isSupported(url: unsupportedURL))

        let nonFileURL = URL(string: "https://example.com/book.epub")!
        XCTAssertNil(BookFormat.detect(url: nonFileURL))
        XCTAssertFalse(BookFormat.isSupported(url: nonFileURL))
    }

    func testSupportedContentTypesAndExtensions() {
        let types = BookFormat.supportedContentTypes
        XCTAssertEqual(types.count, 4)
        XCTAssertTrue(types.contains(.html))
        XCTAssertTrue(types.contains(.plainText))

        let extensions = BookFormat.supportedExtensions
        XCTAssertTrue(extensions.contains("epub"))
        XCTAssertTrue(extensions.contains("html"))
        XCTAssertTrue(extensions.contains("htm"))
        XCTAssertTrue(extensions.contains("xhtml"))
        XCTAssertTrue(extensions.contains("md"))
        XCTAssertTrue(extensions.contains("markdown"))
        XCTAssertTrue(extensions.contains("txt"))
        XCTAssertTrue(extensions.contains("text"))
    }
}
