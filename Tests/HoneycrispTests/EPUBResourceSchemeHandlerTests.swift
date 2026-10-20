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
}
