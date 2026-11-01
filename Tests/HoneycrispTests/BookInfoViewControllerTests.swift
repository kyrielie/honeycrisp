import AppKit
import XCTest
@testable import Honeycrisp

/// Smoke tests for the Book Info sheet's structure. They do not check pixel layout; that needs a
/// manual look (scrolling, wrapping, dark mode).
final class BookInfoViewControllerTests: XCTestCase {

    func testPlainBookHasNoAO3SectionAndKeepsTheOriginalSheetHeight() {
        let controller = BookInfoViewController(package: makePackage(), sourceURL: nil)
        _ = controller.view
        XCTAssertEqual(controller.view.frame.height, 420)
        XCTAssertFalse(texts(in: controller.view).contains("Archive of Our Own"))
        XCTAssertTrue(texts(in: controller.view).contains("Publisher:"))
    }

    func testAO3FieldsRenderAsOrdinaryRowsUnderTheirOwnHeading() {
        var record = AO3MetadataRecord()
        record.fandoms = ["Fandom A"]
        record.relationships = ["Person One/Person Two"]
        record.additionalTags = ["Tag One", "Tag Two"]
        let controller = BookInfoViewController(package: makePackage(), sourceURL: nil, ao3: record)
        _ = controller.view

        let all = texts(in: controller.view)
        XCTAssertTrue(all.contains("Archive of Our Own"))
        XCTAssertTrue(all.contains("Fandoms:"))
        XCTAssertTrue(all.contains("Fandom A"))
        XCTAssertTrue(all.contains("Relationships:"))
        XCTAssertTrue(all.contains("Tag One, Tag Two"))
        XCTAssertGreaterThan(controller.view.frame.height, 420)
    }

    func testWholePanelScrollsAsOneScrollViewWithNoNestedTextView() {
        var record = AO3MetadataRecord()
        record.fandoms = ["Fandom A"]
        let controller = BookInfoViewController(package: makePackage(), sourceURL: nil, ao3: record)
        _ = controller.view

        let views = allSubviews(of: controller.view)
        XCTAssertEqual(views.filter { $0 is NSScrollView }.count, 1)
        XCTAssertFalse(views.contains { $0 is NSTextView })
    }

    func testDescriptionRendersAsARowInTheSinglePanel() {
        let controller = BookInfoViewController(package: makePackage(description: "<p>A &amp; B</p>"), sourceURL: nil)
        _ = controller.view

        let all = texts(in: controller.view)
        XCTAssertTrue(all.contains("Description:"))
        XCTAssertTrue(all.contains("A & B"))
        XCTAssertEqual(allSubviews(of: controller.view).filter { $0 is NSScrollView }.count, 1)
    }

    func testAO3SummaryRendersAsARowAndReplacesTheDescription() {
        var record = AO3MetadataRecord()
        record.summary = "The work summary."
        let controller = BookInfoViewController(package: makePackage(description: "Same text."), sourceURL: nil, ao3: record)
        _ = controller.view

        let all = texts(in: controller.view)
        XCTAssertTrue(all.contains("Summary:"))
        XCTAssertTrue(all.contains("The work summary."))
        XCTAssertFalse(all.contains("Description:"))
    }

    func testDoneButtonIsOutsideTheScrollingPanel() throws {
        let controller = BookInfoViewController(package: makePackage(), sourceURL: nil)
        _ = controller.view

        let scroll = try XCTUnwrap(allSubviews(of: controller.view).first { $0 is NSScrollView })
        let button = try XCTUnwrap(allSubviews(of: controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Done" })
        XCTAssertFalse(button.isDescendant(of: scroll))
    }

    // MARK: - Helpers

    private func makePackage(description: String? = nil) -> EPUBPackage {
        EPUBPackage(
            rootFolder: URL(fileURLWithPath: "/tmp/book-info-vc"),
            spineURLs: [],
            title: "T",
            author: "A",
            coverURL: nil,
            bookDescription: description
        )
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func texts(in view: NSView) -> [String] {
        allSubviews(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }
}
