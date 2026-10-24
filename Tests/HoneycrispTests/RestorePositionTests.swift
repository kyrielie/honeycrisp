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
        XCTAssertEqual(RestorePosition.fragment("chapter-heading").bootstrapJS, "window.qlNavigateToFragment(\"chapter-heading\");")
    }
}
