import XCTest
@testable import Honeycrisp

final class RestorePositionTests: XCTestCase {
    func testFractionRestoreClampsValuesToValidRange() {
        XCTAssertEqual(RestorePosition.fraction(-0.25).bootstrapJS, "window.qlScrollToFraction(0.0);")
        XCTAssertEqual(RestorePosition.fraction(1.25).bootstrapJS, "window.qlScrollToFraction(1.0);")
    }

    func testRestorePositionsGenerateExpectedBootstrapCalls() {
        XCTAssertEqual(RestorePosition.start.bootstrapJS, "window.qlScrollToColumn(0);")
        XCTAssertEqual(RestorePosition.end.bootstrapJS, "window.qlScrollToColumn(window.qlColumnCount() - 1);")
        XCTAssertEqual(RestorePosition.characterOffset(321).bootstrapJS, "window.qlNavigateToOffset(321);")
    }

    func testScrollRestorePlanHandlesLegacyAndChapterLocalLayouts() {
        XCTAssertEqual(ScrollRestorePlan.choose(saved: nil), .none)
        XCTAssertEqual(
            ScrollRestorePlan.choose(saved: (spineIndex: 0, characterOffset: 42, anchorLayout: EPUBAnchor.legacyLayout)),
            .wholeDocument(42)
        )
        XCTAssertEqual(
            ScrollRestorePlan.choose(saved: (spineIndex: 3, characterOffset: 42, anchorLayout: EPUBAnchor.legacyLayout)),
            .chapter(index: 3, offset: 42)
        )
        XCTAssertEqual(
            ScrollRestorePlan.choose(saved: (spineIndex: 2, characterOffset: 0, anchorLayout: EPUBAnchor.currentLayout)),
            .chapter(index: 2, offset: 0)
        )
        XCTAssertEqual(
            ScrollRestorePlan.choose(saved: (spineIndex: 0, characterOffset: 0, anchorLayout: EPUBAnchor.currentLayout)),
            .none
        )
    }
}
