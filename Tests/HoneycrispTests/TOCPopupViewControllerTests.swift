// TOCPopupViewControllerTests.swift
// Tests for modernized TOCPopupViewController, keyboard navigation, and TOCPanel host resolution.

import XCTest
@testable import Honeycrisp

final class TOCPopupViewControllerTests: XCTestCase {

    private func makeEntry(
        title: String,
        file: String,
        fragment: String? = nil,
        depth: Int = 0,
        playOrder: Int = 1,
        children: [TOCEntry] = []
    ) -> TOCEntry {
        let fragPart = fragment.map { "#\($0)" } ?? ""
        let url = URL(string: "file:///book/Text/\(file)\(fragPart)")!
        return TOCEntry(
            title: title,
            href: "Text/\(file)\(fragPart)",
            absoluteURL: url,
            playOrder: playOrder,
            depth: depth,
            children: children
        )
    }

    private func makeSpineURLs(_ names: [String]) -> [URL] {
        names.map { URL(string: "file:///book/Text/\($0)")! }
    }

    func testPrepareForDisplayRevealsAndSelectsNestedCurrentEntry() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let l3 = makeEntry(title: "Nested Section", file: "c1.xhtml", fragment: "nested", depth: 2)
        let l2 = makeEntry(title: "Middle", file: "c1.xhtml", depth: 1, children: [l3])
        let l1 = makeEntry(title: "Top", file: "c1.xhtml", depth: 0, children: [l2])

        let model = TOCModel(entries: [l1], spineURLs: spine)
        model.setCurrent(TOCLocation(spineIndex: 0, fragment: "nested"))

        let popup = TOCPopupViewController(model: model)
        _ = popup.view
        popup.prepareForDisplay()

        XCTAssertTrue(model.isExpanded(model.roots[0]))
        XCTAssertTrue(model.isExpanded(model.roots[0].children[0]))

        let selectedRow = popup.outlineView.selectedRow
        XCTAssertGreaterThanOrEqual(selectedRow, 0)
        let selectedItem = popup.outlineView.item(atRow: selectedRow) as? TOCItem
        XCTAssertEqual(selectedItem?.title, "Nested Section")
    }

    func testFilterSelectsFirstSelectableMatchAndReturnActivatesIt() {
        let spine = makeSpineURLs(["c1.xhtml", "c2.xhtml"])
        let e1 = makeEntry(title: "Chapter One", file: "c1.xhtml")
        let e2 = makeEntry(title: "Chapter Two", file: "c2.xhtml")

        let model = TOCModel(entries: [e1, e2], spineURLs: spine)
        let popup = TOCPopupViewController(model: model)
        _ = popup.view
        popup.prepareForDisplay()

        var selectedEntry: TOCEntry?
        popup.onSelect = { selectedEntry = $0 }

        popup.searchField.stringValue = "Two"
        popup.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: popup.searchField))

        let selectedRow = popup.outlineView.selectedRow
        XCTAssertGreaterThanOrEqual(selectedRow, 0)
        let selectedItem = popup.outlineView.item(atRow: selectedRow) as? TOCItem
        XCTAssertEqual(selectedItem?.title, "Chapter Two")

        let handled = popup.control(
            popup.searchField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(selectedEntry?.title, "Chapter Two")
    }

    func testEscapeClearsFilterThenDismisses() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let e1 = makeEntry(title: "Chapter One", file: "c1.xhtml")

        let model = TOCModel(entries: [e1], spineURLs: spine)
        let popup = TOCPopupViewController(model: model)
        _ = popup.view
        popup.prepareForDisplay()

        var dismissed = false
        popup.onDismiss = { dismissed = true }

        // Step 1: Type query
        popup.searchField.stringValue = "Chapter"
        popup.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: popup.searchField))
        XCTAssertEqual(popup.model.filter, "Chapter")

        // First escape clears query
        let handledFirst = popup.control(
            popup.searchField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertTrue(handledFirst)
        XCTAssertEqual(popup.searchField.stringValue, "")
        XCTAssertEqual(popup.model.filter, "")
        XCTAssertFalse(dismissed)

        // Second escape dismisses
        let handledSecond = popup.control(
            popup.searchField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertTrue(handledSecond)
        XCTAssertTrue(dismissed)
    }

    func testMoveDownSkipsUnresolvedRows() {
        let spine = makeSpineURLs(["c2.xhtml"])
        let unlisted = makeEntry(title: "Unresolved Header", file: "unlisted.xhtml", depth: 0)
        let listed = makeEntry(title: "Selectable Chapter", file: "c2.xhtml", depth: 0)

        let model = TOCModel(entries: [unlisted, listed], spineURLs: spine)
        let popup = TOCPopupViewController(model: model)
        _ = popup.view
        popup.prepareForDisplay()

        // Down arrow from no selection or search field
        let handled = popup.control(
            popup.searchField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        )
        XCTAssertTrue(handled)

        let selectedRow = popup.outlineView.selectedRow
        XCTAssertGreaterThanOrEqual(selectedRow, 0)
        let selectedItem = popup.outlineView.item(atRow: selectedRow) as? TOCItem
        XCTAssertEqual(selectedItem?.title, "Selectable Chapter")
        XCTAssertTrue(selectedItem?.isSelectable ?? false)
    }

    func testUnresolvedItemsAreNotSelectable() {
        let spine = makeSpineURLs(["c2.xhtml"])
        let unlisted = makeEntry(title: "Unresolved", file: "unlisted.xhtml")
        let model = TOCModel(entries: [unlisted], spineURLs: spine)

        let popup = TOCPopupViewController(model: model)
        _ = popup.view
        popup.prepareForDisplay()

        let item = model.roots[0]
        XCTAssertFalse(popup.outlineView(popup.outlineView, shouldSelectItem: item))
    }

    func testPanelCanBecomeKeyButNotMain() {
        let panel = TOCPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testHostWindowResolvesChildPanelToItsParent() {
        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let panel = TOCPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        parentWindow.addChildWindow(panel, ordered: .above)

        XCTAssertTrue(TOCPanel.hostWindow(for: panel) === parentWindow)
        XCTAssertTrue(TOCPanel.hostWindow(for: parentWindow) === parentWindow)
        XCTAssertNil(TOCPanel.hostWindow(for: nil))
    }
}
