// TOCModelTests.swift
// Tests for TOCModel hierarchy, resolution, filtering, expansion, and selection.

import XCTest
@testable import Honeycrisp

final class TOCModelTests: XCTestCase {

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

    func testResolvesSpineIndexAndFragmentAndLeavesUnlistedFilesUnresolved() {
        let spine = makeSpineURLs(["c1.xhtml", "c2.xhtml"])
        let entries = [
            makeEntry(title: "Chapter 1", file: "c1.xhtml", fragment: "sec1"),
            makeEntry(title: "Unlisted Extra", file: "appendix.xhtml"),
        ]
        let model = TOCModel(entries: entries, spineURLs: spine)

        XCTAssertEqual(model.roots.count, 2)
        XCTAssertEqual(model.roots[0].spineIndex, 0)
        XCTAssertEqual(model.roots[0].fragment, "sec1")
        XCTAssertTrue(model.roots[0].isSelectable)

        XCTAssertNil(model.roots[1].spineIndex)
        XCTAssertNil(model.roots[1].fragment)
        XCTAssertFalse(model.roots[1].isSelectable)
    }

    func testDuplicateSpineURLsResolveToFirstIndex() {
        let spine = [
            URL(string: "file:///book/Text/dup.xhtml")!,
            URL(string: "file:///book/Text/other.xhtml")!,
            URL(string: "file:///book/Text/dup.xhtml")!,
        ]
        let entries = [makeEntry(title: "Dup", file: "dup.xhtml")]
        let model = TOCModel(entries: entries, spineURLs: spine)

        XCTAssertEqual(model.roots[0].spineIndex, 0)
    }

    func testItemsAreInPreOrderAndStableAcrossReads() {
        let spine = makeSpineURLs(["c1.xhtml", "c2.xhtml", "c3.xhtml"])
        let subChild = makeEntry(title: "1.1.1", file: "c1.xhtml", depth: 2, playOrder: 3)
        let child1 = makeEntry(title: "1.1", file: "c1.xhtml", depth: 1, playOrder: 2, children: [subChild])
        let root1 = makeEntry(title: "1", file: "c1.xhtml", depth: 0, playOrder: 1, children: [child1])
        let root2 = makeEntry(title: "2", file: "c2.xhtml", depth: 0, playOrder: 4)

        let model = TOCModel(entries: [root1, root2], spineURLs: spine)

        XCTAssertEqual(model.items.map(\.title), ["1", "1.1", "1.1.1", "2"])
        XCTAssertTrue(model.roots[0] === model.items[0])
        XCTAssertTrue(model.roots[0].children[0] === model.items[1])
        XCTAssertTrue(model.roots[0].children[0].children[0] === model.items[2])
        XCTAssertTrue(model.roots[1] === model.items[3])
    }

    func testCurrentPrefersExactFragmentMatch() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let fileLevel = makeEntry(title: "C1", file: "c1.xhtml", fragment: nil)
        let sec1 = makeEntry(title: "C1 Sec 1", file: "c1.xhtml", fragment: "sec1")
        let sec2 = makeEntry(title: "C1 Sec 2", file: "c1.xhtml", fragment: "sec2")
        let model = TOCModel(entries: [fileLevel, sec1, sec2], spineURLs: spine)

        let item = model.setCurrent(TOCLocation(spineIndex: 0, fragment: "sec2"))
        XCTAssertEqual(item?.title, "C1 Sec 2")
        XCTAssertEqual(model.current?.title, "C1 Sec 2")
    }

    func testCurrentWithoutFragmentPrefersFileLevelEntry() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let sec1 = makeEntry(title: "C1 Sec 1", file: "c1.xhtml", fragment: "sec1")
        let fileLevel = makeEntry(title: "C1 File", file: "c1.xhtml", fragment: nil)
        let model = TOCModel(entries: [sec1, fileLevel], spineURLs: spine)

        let item = model.setCurrent(TOCLocation(spineIndex: 0, fragment: nil))
        XCTAssertEqual(item?.title, "C1 File")
    }

    func testCurrentFallsBackToFirstEntryInFileWhenFragmentIsUnknown() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let sec1 = makeEntry(title: "C1 Sec 1", file: "c1.xhtml", fragment: "sec1")
        let sec2 = makeEntry(title: "C1 Sec 2", file: "c1.xhtml", fragment: "sec2")
        let model = TOCModel(entries: [sec1, sec2], spineURLs: spine)

        let item = model.setCurrent(TOCLocation(spineIndex: 0, fragment: "unknown_anchor"))
        XCTAssertEqual(item?.title, "C1 Sec 1")
    }

    func testCurrentFallsBackToNearestPrecedingEntryForUnlistedChapter() {
        let spine = makeSpineURLs(["c0.xhtml", "c1.xhtml", "c2_unlisted.xhtml", "c3.xhtml"])
        let e0 = makeEntry(title: "Chapter 0", file: "c0.xhtml")
        let e1 = makeEntry(title: "Chapter 1", file: "c1.xhtml")
        let e3 = makeEntry(title: "Chapter 3", file: "c3.xhtml")
        let model = TOCModel(entries: [e0, e1, e3], spineURLs: spine)

        // c2_unlisted is at spine index 2, should fall back to greatest preceding: index 1 ("Chapter 1")
        let item = model.setCurrent(TOCLocation(spineIndex: 2, fragment: nil))
        XCTAssertEqual(item?.title, "Chapter 1")
    }

    func testCurrentIsNilBeforeFirstEntry() {
        let spine = makeSpineURLs(["cover.xhtml", "c1.xhtml"])
        let e1 = makeEntry(title: "Chapter 1", file: "c1.xhtml")
        let model = TOCModel(entries: [e1], spineURLs: spine)

        // spine index 0 is cover, preceding has no listed entry
        let item = model.setCurrent(TOCLocation(spineIndex: 0, fragment: nil))
        XCTAssertNil(item)
        XCTAssertNil(model.current)
    }

    func testCurrentKeepsFragmentWhileSpineIndexUnchanged() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let fileLevel = makeEntry(title: "Chapter 1", file: "c1.xhtml")
        let sec1 = makeEntry(title: "Section 1", file: "c1.xhtml", fragment: "sec1")
        let model = TOCModel(entries: [fileLevel, sec1], spineURLs: spine)

        model.setCurrent(TOCLocation(spineIndex: 0, fragment: "sec1"))
        XCTAssertEqual(model.current?.title, "Section 1")

        // Scroll update sends nil fragment for same spineIndex: should stay sticky
        model.setCurrent(TOCLocation(spineIndex: 0, fragment: nil))
        XCTAssertEqual(model.current?.title, "Section 1")
    }

    func testCurrentDropsFragmentWhenChapterChanges() {
        let spine = makeSpineURLs(["c1.xhtml", "c2.xhtml"])
        let sec1 = makeEntry(title: "C1 Sec 1", file: "c1.xhtml", fragment: "sec1")
        let c2 = makeEntry(title: "Chapter 2", file: "c2.xhtml")
        let model = TOCModel(entries: [sec1, c2], spineURLs: spine)

        model.setCurrent(TOCLocation(spineIndex: 0, fragment: "sec1"))
        XCTAssertEqual(model.current?.title, "C1 Sec 1")

        // Chapter changes to 1 (c2.xhtml) with nil fragment: drops previous fragment
        model.setCurrent(TOCLocation(spineIndex: 1, fragment: nil))
        XCTAssertEqual(model.current?.title, "Chapter 2")
    }

    func testTitleForSpineIndexMatchesLegacyShallowestRule() {
        let spine = makeSpineURLs(["part1.xhtml", "part2.xhtml"])
        let subEntry = makeEntry(title: "Sub Chapter", file: "part1.xhtml", depth: 2, playOrder: 2)
        let mainEntry = makeEntry(title: "Main Chapter", file: "part1.xhtml", depth: 0, playOrder: 1, children: [subEntry])
        let model = TOCModel(entries: [mainEntry], spineURLs: spine)

        XCTAssertEqual(model.title(forSpineIndex: 0), "Main Chapter")
    }

    func testTitleCollapsesInteriorWhitespace() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let entry = makeEntry(title: "  Chapter   \n  One  \t With   Spaces  ", file: "c1.xhtml")
        let model = TOCModel(entries: [entry], spineURLs: spine)

        XCTAssertEqual(model.title(forSpineIndex: 0), "Chapter One With Spaces")
        XCTAssertEqual(model.roots[0].title, "Chapter One With Spaces")
    }

    func testInitialExpansionIsTopLevelOnly() {
        let spine = makeSpineURLs(["c1.xhtml", "c2.xhtml"])
        let subChild = makeEntry(title: "SubChild", file: "c1.xhtml", depth: 2)
        let child = makeEntry(title: "Child", file: "c1.xhtml", depth: 1, children: [subChild])
        let rootWithChildren = makeEntry(title: "Root1", file: "c1.xhtml", depth: 0, children: [child])
        let rootNoChildren = makeEntry(title: "Root2", file: "c2.xhtml", depth: 0)

        let model = TOCModel(entries: [rootWithChildren, rootNoChildren], spineURLs: spine)

        XCTAssertTrue(model.isExpanded(model.roots[0]))
        XCTAssertFalse(model.isExpanded(model.roots[0].children[0]))
        XCTAssertFalse(model.isExpanded(model.roots[1]))
    }

    func testRevealCurrentExpandsAllAncestorsOfANestedEntry() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let l3 = makeEntry(title: "L3", file: "c1.xhtml", fragment: "anchor3", depth: 2)
        let l2 = makeEntry(title: "L2", file: "c1.xhtml", depth: 1, children: [l3])
        let l1 = makeEntry(title: "L1", file: "c1.xhtml", depth: 0, children: [l2])

        let model = TOCModel(entries: [l1], spineURLs: spine)
        let item = model.setCurrent(TOCLocation(spineIndex: 0, fragment: "anchor3"))
        XCTAssertEqual(item?.title, "L3")

        model.revealCurrent()
        XCTAssertTrue(model.isExpanded(model.roots[0]))
        XCTAssertTrue(model.isExpanded(model.roots[0].children[0]))
    }

    func testFilterMatchesCaseDiacriticWidthAndAllTokens() {
        let spine = makeSpineURLs(["c1.xhtml", "c2.xhtml"])
        let e1 = makeEntry(title: "Café au Lait Part One", file: "c1.xhtml")
        let e2 = makeEntry(title: "Other Content", file: "c2.xhtml")
        let model = TOCModel(entries: [e1, e2], spineURLs: spine)

        model.setFilter("cafe part")
        XCTAssertTrue(model.isFiltering)
        XCTAssertTrue(model.isMatch(model.roots[0]))
        XCTAssertFalse(model.isMatch(model.roots[1]))
    }

    func testFilterKeepsAncestorsOfMatchesAndHidesTheRest() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let leaf = makeEntry(title: "Target Match", file: "c1.xhtml", depth: 2)
        let middle = makeEntry(title: "Middle Parent", file: "c1.xhtml", depth: 1, children: [leaf])
        let root = makeEntry(title: "Top Root", file: "c1.xhtml", depth: 0, children: [middle])
        let sibling = makeEntry(title: "Unrelated Sibling", file: "c1.xhtml", depth: 0)

        let model = TOCModel(entries: [root, sibling], spineURLs: spine)
        model.setFilter("Target")

        let visibleRoots = model.visibleChildren(of: nil)
        XCTAssertEqual(visibleRoots.map(\.title), ["Top Root"])

        let visibleMiddle = model.visibleChildren(of: visibleRoots[0])
        XCTAssertEqual(visibleMiddle.map(\.title), ["Middle Parent"])

        let visibleLeaf = model.visibleChildren(of: visibleMiddle[0])
        XCTAssertEqual(visibleLeaf.map(\.title), ["Target Match"])
    }

    func testFilterIgnoresStoredExpansionAndExpandsAncestors() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let leaf = makeEntry(title: "Target Match", file: "c1.xhtml", depth: 1)
        let root = makeEntry(title: "Top Root", file: "c1.xhtml", depth: 0, children: [leaf])

        let model = TOCModel(entries: [root], spineURLs: spine)
        // Collapse root
        model.setExpanded(false, for: model.roots[0])
        XCTAssertFalse(model.isExpanded(model.roots[0]))

        // Filtering expands visible parent with matching children
        model.setFilter("Target")
        XCTAssertTrue(model.isExpanded(model.roots[0]))
    }

    func testClearingFilterRestoresStoredExpansion() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let leaf = makeEntry(title: "Leaf", file: "c1.xhtml", depth: 1)
        let root = makeEntry(title: "Root", file: "c1.xhtml", depth: 0, children: [leaf])

        let model = TOCModel(entries: [root], spineURLs: spine)
        model.setExpanded(false, for: model.roots[0])
        XCTAssertFalse(model.isExpanded(model.roots[0]))

        model.setFilter("Leaf")
        XCTAssertTrue(model.isExpanded(model.roots[0]))

        model.setFilter("")
        XCTAssertFalse(model.isFiltering)
        XCTAssertFalse(model.isExpanded(model.roots[0]))
    }

    func testWhitespaceOnlyFilterIsNotFiltering() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let root = makeEntry(title: "Root", file: "c1.xhtml")
        let model = TOCModel(entries: [root], spineURLs: spine)

        model.setFilter("    \n   ")
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.filter, "")
    }

    func testSetExpandedIsIgnoredWhileFiltering() {
        let spine = makeSpineURLs(["c1.xhtml"])
        let leaf = makeEntry(title: "Match", file: "c1.xhtml", depth: 1)
        let root = makeEntry(title: "Root", file: "c1.xhtml", depth: 0, children: [leaf])

        let model = TOCModel(entries: [root], spineURLs: spine)
        XCTAssertTrue(model.isExpanded(model.roots[0]))

        model.setFilter("Match")
        model.setExpanded(false, for: model.roots[0])  // should be ignored

        model.setFilter("")
        XCTAssertTrue(model.isExpanded(model.roots[0]))
    }

    func testFirstSelectableMatchSkipsUnresolvedItems() {
        let spine = makeSpineURLs(["c2.xhtml"])
        let unlisted = makeEntry(title: "Part One Intro", file: "unlisted.xhtml", depth: 0)
        let listed = makeEntry(title: "Part One Main", file: "c2.xhtml", depth: 0)

        let model = TOCModel(entries: [unlisted, listed], spineURLs: spine)
        model.setFilter("Part One")

        XCTAssertEqual(model.firstSelectableMatch?.title, "Part One Main")
    }
}
