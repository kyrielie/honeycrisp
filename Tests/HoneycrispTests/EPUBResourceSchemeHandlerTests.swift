import Foundation
import WebKit
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

    func testAppResourceMimeOverrideForHTML() {
        let flowURL = URL(fileURLWithPath: "__app/flow.html")
        let htmURL = URL(fileURLWithPath: "__app/index.htm")
        let bookHTML = URL(fileURLWithPath: "Text/chapter.html")
        let xhtmlURL = URL(fileURLWithPath: "__app/chapter.xhtml")

        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: flowURL, isAppResource: true), "text/html")
        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: htmURL, isAppResource: true), "text/html")
        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: bookHTML, isAppResource: false), "application/xhtml+xml")
        XCTAssertEqual(EPUBResourceSchemeHandler.mimeType(for: xhtmlURL, isAppResource: true), "application/xhtml+xml")
    }

    @MainActor
    func testAppResourceHtmlWithVoidTagsAndEntitiesLoadsInWebView() throws {
        let handler = EPUBResourceSchemeHandler(rootFolder: FileManager.default.temporaryDirectory)
        let html = "<!doctype html><html><body><p>Hello<br>World&nbsp;Test</p></body></html>"
        handler.appResources["__app/flow.html"] = Data(html.utf8)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: EPUBResourceSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: config)

        let loaded = expectation(description: "Flow HTML loaded")
        let delegate = NavigationWatcher { loaded.fulfill() }
        webView.navigationDelegate = delegate

        webView.load(URLRequest(url: URL(string: "honeycrisp-epub://book/__app/flow.html")!))
        wait(for: [loaded], timeout: 5.0)

        let textExpectation = expectation(description: "Read body text")
        webView.evaluateJavaScript("document.body.innerText") { result, _ in
            let text = result as? String ?? ""
            XCTAssertTrue(text.contains("Hello"), "Loaded text should contain Hello")
            XCTAssertTrue(text.contains("World"), "Loaded text should contain World")
            textExpectation.fulfill()
        }
        wait(for: [textExpectation], timeout: 5.0)
        _ = delegate
    }
}

private final class NavigationWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
