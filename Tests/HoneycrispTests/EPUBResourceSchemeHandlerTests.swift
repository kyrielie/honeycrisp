import Foundation
import XCTest
@testable import Honeycrisp

final class EPUBResourceSchemeHandlerTests: XCTestCase {
    func testResolverKeepsResourcesInsideBookRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chapter = URL(string: "honeycrisp-epub://book/Text/chapter%201.xhtml")!
        XCTAssertEqual(
            EPUBResourceSchemeHandler.resourceURL(for: chapter, root: root)?.path,
            root.appendingPathComponent("Text/chapter 1.xhtml").path
        )
        let traversal = URL(string: "honeycrisp-epub://book/%2e%2e/private.txt")!
        XCTAssertNil(EPUBResourceSchemeHandler.resourceURL(for: traversal, root: root))
        let otherScheme = URL(string: "file:///tmp/secret")!
        XCTAssertNil(EPUBResourceSchemeHandler.resourceURL(for: otherScheme, root: root))
    }

    func testMimeTypesCoverCommonEpubResources() {
        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "chapter.xhtml")), "application/xhtml+xml")
        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "style.css")), "text/css")
        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "image.svg")), "image/svg+xml")
        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "unknown.bin")), "application/octet-stream")
    }

    func testActiveTaskSetCompletesATaskOnlyWhileItIsActive() {
        let first = NSObject()
        let second = NSObject()
        var tasks = ActiveTaskSet()
        tasks.insert(ObjectIdentifier(first))
        tasks.insert(ObjectIdentifier(second))

        XCTAssertTrue(tasks.contains(ObjectIdentifier(first)))
        XCTAssertTrue(tasks.remove(ObjectIdentifier(first)))
        XCTAssertFalse(tasks.contains(ObjectIdentifier(first)))
        XCTAssertFalse(tasks.remove(ObjectIdentifier(first)), "a stopped or finished task must not complete twice")
        XCTAssertTrue(tasks.contains(ObjectIdentifier(second)))
    }

    func testRootFolderIsNormalizedWhenReassigned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = EPUBResourceSchemeHandler(rootFolder: URL(fileURLWithPath: "/nonexistent"))
        handler.rootFolder = root

        XCTAssertEqual(handler.rootFolder.path, root.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testAppResourceKeyOnlyForAppPrefix() {
        let key = { EPUBResourceSchemeHandler.appResourceKey(for: URL(string: $0)!) }
        XCTAssertEqual(key("honeycrisp-epub://book/__app/reader.css"), ServedChapter.readerStylesheetPath)
        XCTAssertEqual(key("honeycrisp-epub://book/__app/shell.html"), "__app/shell.html")
        XCTAssertNil(key("honeycrisp-epub://book/Text/chapter.xhtml"))
        XCTAssertNil(key("honeycrisp-epub://book/__app/"), "the bare prefix names no resource")
        XCTAssertNil(key("honeycrisp-epub://book/__apple/reader.css"))
        XCTAssertNil(key("honeycrisp-epub://book/x/__app/reader.css"))
    }

    func testAppResourceKeyRejectsTraversalForeignHostAndQuery() {
        let key = { EPUBResourceSchemeHandler.appResourceKey(for: URL(string: $0)!) }
        XCTAssertNil(key("honeycrisp-epub://book/__app/%2e%2e/secret.css"))
        XCTAssertNil(key("honeycrisp-epub://book/__app/../secret.css"))
        XCTAssertNil(key("honeycrisp-epub://other/__app/reader.css"))
        XCTAssertNil(key("https://book/__app/reader.css"))
        XCTAssertNil(key("honeycrisp-epub://book/__app/reader.css?x=1"))
    }

    func testShouldTransformOnlyMarkupExtensions() {
        let transforms = { EPUBResourceSchemeHandler.shouldTransform(URL(fileURLWithPath: $0)) }
        XCTAssertTrue(transforms("Text/chapter.xhtml"))
        XCTAssertTrue(transforms("Text/Chapter.HTML"))
        XCTAssertTrue(transforms("Text/old.htm"))
        XCTAssertFalse(transforms("Styles/book.css"))
        XCTAssertFalse(transforms("Images/pic.png"))
        XCTAssertFalse(transforms("Fonts/book.woff2"))
    }
}
