import Foundation
import XCTest
@testable import Honeycrisp

final class LocatorTests: XCTestCase {
    func testMatchingLayoutRestoresByOffset() {
        let locator = Locator.flow(resource: 2, offset: 412, layout: EPUBAnchor.currentLayout, fraction: 0.8)
        XCTAssertEqual(locator.flowRestoreTarget, .offset(resource: 2, offset: 412))
    }

    func testMismatchedLayoutRestoresByClampedFraction() {
        let locator = Locator.flow(resource: 3, offset: 412, layout: EPUBAnchor.currentLayout - 1, fraction: 1.4)
        XCTAssertEqual(locator.flowRestoreTarget, .fraction(resource: 3, fraction: 1))
    }

    func testLocatorCodableRoundTrip() throws {
        let locator = Locator.flow(resource: 1, offset: 45, layout: 7, fraction: 0.25)
        let decoded = try JSONDecoder().decode(Locator.self, from: JSONEncoder().encode(locator))
        XCTAssertEqual(decoded, locator)
    }

    func testProgressUsesTextLengthsAndCurrentOffset() {
        let locator = Locator.flow(resource: 1, offset: 50, layout: 1, fraction: 0.9)
        let progress = ReadingProgress.fraction(
            for: locator,
            resources: [
                ResourceProgressMeasure(textLength: 100, byteSize: 500),
                ResourceProgressMeasure(textLength: 200, byteSize: 900),
            ]
        )
        XCTAssertEqual(progress ?? -1, 0.5, accuracy: 0.0001)
    }

    func testProgressFallsBackToByteSizesAndSavedFraction() {
        let locator = Locator.flow(resource: 1, offset: 50, layout: 1, fraction: 0.5)
        let progress = ReadingProgress.fraction(
            for: locator,
            resources: [
                ResourceProgressMeasure(textLength: nil, byteSize: 300),
                ResourceProgressMeasure(textLength: nil, byteSize: 100),
            ]
        )
        XCTAssertEqual(progress ?? -1, 0.875, accuracy: 0.0001)
    }

    func testProgressReturnsNilForPagedOrUnknownResource() {
        let resources = [ResourceProgressMeasure(textLength: 10, byteSize: 20)]
        XCTAssertNil(ReadingProgress.fraction(for: .page(index: 2), resources: resources))
        XCTAssertNil(ReadingProgress.fraction(
            for: .flow(resource: 2, offset: 0, layout: 1, fraction: 0), resources: resources
        ))
    }
}
