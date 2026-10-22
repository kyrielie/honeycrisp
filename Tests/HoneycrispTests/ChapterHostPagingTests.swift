import XCTest
@testable import Honeycrisp

/// Roadmap M4 pass 7.2: the pure hand-off and geometry rules. `PaginationEngine.invalidate` has no test
/// (no tests exist for `PaginationEngine` beyond `RestorePosition`).
final class ChapterHostPagingTests: XCTestCase {
    func testHandoffForwardIsNextStart() throws {
        let result = try XCTUnwrap(ChapterHostPaging.handoff(from: 2, forward: true, count: 5))
        XCTAssertEqual(result.index, 3)
        XCTAssertEqual(result.restore.bootstrapJS, RestorePosition.start.bootstrapJS)
    }

    func testHandoffBackIsPreviousEnd() throws {
        let result = try XCTUnwrap(ChapterHostPaging.handoff(from: 2, forward: false, count: 5))
        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.restore.bootstrapJS, RestorePosition.end.bootstrapJS)
    }

    func testHandoffAtBookEdgesIsNil() {
        XCTAssertNil(ChapterHostPaging.handoff(from: 0, forward: false, count: 5))
        XCTAssertNil(ChapterHostPaging.handoff(from: 4, forward: true, count: 5))
        XCTAssertNil(ChapterHostPaging.handoff(from: 0, forward: true, count: 0))
        XCTAssertNil(ChapterHostPaging.handoff(from: 9, forward: false, count: 5))
        XCTAssertNil(ChapterHostPaging.handoff(from: -1, forward: true, count: 5))
    }

    func testRestoreForPositionIsExactCharacterOffset() {
        let result = ChapterHostPaging.restore(for: ChapterHostSurface.Position(resource: 7, offset: 1234))
        XCTAssertEqual(result.resource, 7)
        XCTAssertEqual(result.restore.bootstrapJS, "window.qlNavigateToOffset(1234);")
    }

    func testChangesDocumentIgnoresFragmentsOnly() throws {
        let chapter = try XCTUnwrap(URL(string: "honeycrisp-epub://book/Text/Chapter%201.xhtml"))
        let anchor = try XCTUnwrap(URL(string: "honeycrisp-epub://book/Text/Chapter%201.xhtml#note3"))
        let other = try XCTUnwrap(URL(string: "honeycrisp-epub://book/Text/Chapter%202.xhtml#note3"))
        XCTAssertFalse(ChapterHostPaging.changesDocument(from: chapter, to: anchor))
        XCTAssertFalse(ChapterHostPaging.changesDocument(from: anchor, to: chapter))
        XCTAssertTrue(ChapterHostPaging.changesDocument(from: chapter, to: other))
        XCTAssertTrue(ChapterHostPaging.changesDocument(from: nil, to: anchor))
    }

    func testGeometryCarriesViewportAndSettings() {
        let geometry = ChapterHostPaging.geometry(
            viewport: CGSize(width: 900, height: 700), cols: .two, paddingH: 30, paddingV: 20, maxWidth: 650)
        XCTAssertEqual(
            geometry,
            ChapterHostPagedGeometry(
                viewportWidth: 900, viewportHeight: 700, colsPerScreen: .two, paddingH: 30, paddingV: 20, maxWidth: 650))
    }

    func testGeometryUsesFallbackViewportWhenEmptyAndClampsNegatives() {
        let geometry = ChapterHostPaging.geometry(
            viewport: .zero, cols: .one, paddingH: -5, paddingV: -1, maxWidth: -9)
        XCTAssertEqual(geometry.viewportWidth, 780)
        XCTAssertEqual(geometry.viewportHeight, 920)
        XCTAssertEqual(geometry.paddingH, 0)
        XCTAssertEqual(geometry.paddingV, 0)
        XCTAssertEqual(geometry.maxWidth, 0)
    }

    func testPagedTargetUsesPendingPositionFractionOrStart() {
        let position = ChapterHostPaging.pagedTarget(
            for: .position(ChapterHostSurface.Position(resource: 3, offset: 40)), fallbackIndex: 0, count: 5)
        XCTAssertEqual(position.index, 3)
        XCTAssertEqual(position.restore.bootstrapJS, "window.qlNavigateToOffset(40);")

        let fraction = ChapterHostPaging.pagedTarget(
            for: .fraction(resource: 1, fraction: 0.5), fallbackIndex: 0, count: 5)
        XCTAssertEqual(fraction.index, 1)
        XCTAssertEqual(fraction.restore.bootstrapJS, "window.qlScrollToFraction(0.5);")

        for pending: ChapterHostSurface.Restore? in [nil, .start] {
            let start = ChapterHostPaging.pagedTarget(for: pending, fallbackIndex: 2, count: 5)
            XCTAssertEqual(start.index, 2)
            XCTAssertEqual(start.restore.bootstrapJS, RestorePosition.start.bootstrapJS)
        }
    }

    func testPagedTargetClampsChapterIntoTheBookAndNaNFractionIsZero() {
        let high = ChapterHostPaging.pagedTarget(
            for: .position(ChapterHostSurface.Position(resource: 99, offset: 1)), fallbackIndex: 0, count: 5)
        XCTAssertEqual(high.index, 4)
        let low = ChapterHostPaging.pagedTarget(for: nil, fallbackIndex: -3, count: 5)
        XCTAssertEqual(low.index, 0)
        let nan = ChapterHostPaging.pagedTarget(
            for: .fraction(resource: 2, fraction: .nan), fallbackIndex: 0, count: 5)
        XCTAssertEqual(nan.restore.bootstrapJS, "window.qlScrollToFraction(0.0);")
        XCTAssertEqual(ChapterHostPaging.pagedTarget(for: nil, fallbackIndex: 4, count: 0).index, 0)
    }

    func testToPagedUsesTheScrollPositionAsAnExactOffset() {
        let result = ChapterHostPaging.toPaged(
            from: ChapterHostSurface.Position(resource: 3, offset: 410), activeIndex: 1, count: 5)
        XCTAssertEqual(result.index, 3)
        XCTAssertEqual(result.restore, .position(ChapterHostSurface.Position(resource: 3, offset: 410)))
    }

    func testToPagedWithoutAPositionOpensTheActiveChapterAtItsStart() {
        let result = ChapterHostPaging.toPaged(from: nil, activeIndex: 4, count: 5)
        XCTAssertEqual(result.index, 4)
        XCTAssertEqual(result.restore, .start)
    }

    func testToPagedClampsChapterAndNegativeOffset() {
        let high = ChapterHostPaging.toPaged(
            from: ChapterHostSurface.Position(resource: 9, offset: -3), activeIndex: 0, count: 5)
        XCTAssertEqual(high.index, 4)
        XCTAssertEqual(high.restore, .position(ChapterHostSurface.Position(resource: 4, offset: 0)))
        XCTAssertEqual(ChapterHostPaging.toPaged(from: nil, activeIndex: -2, count: 5).index, 0)
        XCTAssertEqual(ChapterHostPaging.toPaged(from: nil, activeIndex: 3, count: 0).index, 0)
    }

    func testToScrollUsesThePagedOffsetInTheCurrentChapter() {
        let result = ChapterHostPaging.toScroll(index: 2, offset: 1184, count: 5)
        XCTAssertEqual(result.index, 2)
        XCTAssertEqual(result.restore, .position(ChapterHostSurface.Position(resource: 2, offset: 1184)))
    }

    func testToScrollWithoutAnOffsetOpensTheChapterAtItsStart() {
        let result = ChapterHostPaging.toScroll(index: 7, offset: nil, count: 5)
        XCTAssertEqual(result.index, 4)
        XCTAssertEqual(result.restore, .start)
        XCTAssertEqual(ChapterHostPaging.toScroll(index: 1, offset: -5, count: 5).restore,
                       .position(ChapterHostSurface.Position(resource: 1, offset: 0)))
    }
}
