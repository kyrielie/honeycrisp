// DocumentImporterTests.swift
// Tests for unified DocumentImporter dispatching

import XCTest
@testable import Honeycrisp

final class DocumentImporterTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DocumentImporterTests_\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testImportPlainTextDocument() throws {
        let text = """
        Title: The Odyssey
        Author: Homer

        Chapter 1: The Gathering
        Tell me, O Muse, of that ingenious hero.
        """
        let sourceURL = tempDirectory.appendingPathComponent("odyssey.txt")
        try text.write(to: sourceURL, atomically: true, encoding: .utf8)

        let workDir = tempDirectory.appendingPathComponent("work_txt", isDirectory: true)
        let package = try DocumentImporter.importDocument(at: sourceURL, to: workDir)

        XCTAssertEqual(package.title, "The Odyssey")
        XCTAssertEqual(package.author, "Homer")
        XCTAssertEqual(package.spineURLs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.spineURLs[0].path))
    }

    func testImportHTMLDocument() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Web Article</title></head>
        <body>
        <h1>Heading</h1>
        <p>Paragraph text.</p>
        </body>
        </html>
        """
        let sourceURL = tempDirectory.appendingPathComponent("article.html")
        try html.write(to: sourceURL, atomically: true, encoding: .utf8)

        let workDir = tempDirectory.appendingPathComponent("work_html", isDirectory: true)
        let package = try DocumentImporter.importDocument(at: sourceURL, to: workDir)

        XCTAssertEqual(package.title, "Web Article")
        XCTAssertFalse(package.spineURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.spineURLs[0].path))
    }

    func testImportMarkdownDocument() throws {
        let markdown = """
        # Notes on Physics

        This is an introductory guide to mechanics.

        ## Newton's Laws
        An object remains at rest unless acted upon by a force.
        """
        let sourceURL = tempDirectory.appendingPathComponent("notes.md")
        try markdown.write(to: sourceURL, atomically: true, encoding: .utf8)

        let workDir = tempDirectory.appendingPathComponent("work_md", isDirectory: true)
        let package = try DocumentImporter.importDocument(at: sourceURL, to: workDir)

        XCTAssertEqual(package.title, "Notes on Physics")
        XCTAssertEqual(package.spineURLs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.spineURLs[0].path))
    }

    func testImportDirectoryEPUB() throws {
        let epubDir = tempDirectory.appendingPathComponent("test.epub", isDirectory: true)
        let metaInf = epubDir.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let opfXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>EPUB Book</dc:title>
            <dc:creator>Author Name</dc:creator>
          </metadata>
          <manifest>
            <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
          </spine>
        </package>
        """
        try opfXML.write(to: epubDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<html><body><p>Text</p></body></html>".write(
            to: epubDir.appendingPathComponent("chap1.xhtml"),
            atomically: true,
            encoding: .utf8
        )

        let workDir = tempDirectory.appendingPathComponent("work_epub", isDirectory: true)
        let package = try DocumentImporter.importDocument(at: epubDir, to: workDir)

        XCTAssertEqual(package.title, "EPUB Book")
        XCTAssertEqual(package.author, "Author Name")
        XCTAssertEqual(package.spineURLs.count, 1)
    }

    func testImportUnsupportedFormatThrows() throws {
        let sourceURL = tempDirectory.appendingPathComponent("document.pdf")
        try "fake pdf content".write(to: sourceURL, atomically: true, encoding: .utf8)

        let workDir = tempDirectory.appendingPathComponent("work_pdf", isDirectory: true)
        XCTAssertThrowsError(try DocumentImporter.importDocument(at: sourceURL, to: workDir)) { error in
            guard case DocumentImporterError.unsupportedFormat(let ext) = error else {
                XCTFail("Expected unsupportedFormat error, got: \(error)")
                return
            }
            XCTAssertEqual(ext, "pdf")
        }
    }
}
