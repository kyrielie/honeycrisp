import WebKit
import XCTest
@testable import Honeycrisp

@MainActor
final class FlowingSurfaceTests: XCTestCase {
    func testChapterHostSurfaceProperties() {
        let host = ChapterHostSurface()
        let surface: FlowingSurface = host

        XCTAssertEqual(surface.pagerContentWorld, .defaultClient)
        XCTAssertFalse(surface.supportsBookmarks)
        XCTAssertFalse(surface.persistsProgress)
        XCTAssertFalse(surface.persistsPosition)
        XCTAssertTrue(surface.requiresEngineReadyForSpineNavigation)
        XCTAssertTrue(surface.managesScrollWindow)
        XCTAssertTrue(surface.managesPagedChapter)
        XCTAssertTrue(surface.handlesReadingModeToggle)
        XCTAssertTrue(surface.handlesStructuralReload)
        XCTAssertTrue(surface.handlesPaginatedResize)
    }

    func testChapterHostSurfaceTargetForPaginatedRestoreConsumesPending() {
        let host = ChapterHostSurface()
        let surface: FlowingSurface = host

        host.pendingRestore = .position(ChapterHostSurface.Position(resource: 4, offset: 120))
        let target = surface.targetForPaginatedRestore(fallbackIndex: 0, count: 10)

        XCTAssertNotNil(target)
        XCTAssertEqual(target?.index, 4)
        XCTAssertEqual(target?.restore, .characterOffset(120))
        XCTAssertNil(host.pendingRestore, "targetForPaginatedRestore must clear pendingRestore after consuming it")
    }

    func testChapterHostSurfaceFallbackWhenPendingRestoreIsNil() {
        let host = ChapterHostSurface()
        let surface: FlowingSurface = host

        host.pendingRestore = nil
        let target = surface.targetForPaginatedRestore(fallbackIndex: 2, count: 5)

        XCTAssertNotNil(target)
        XCTAssertEqual(target?.index, 2)
        XCTAssertEqual(target?.restore, .start)
    }

    func testChapterHostSurfaceDidFinishNavigationHandled() {
        let host = ChapterHostSurface()
        let surface: FlowingSurface = host

        let handled = surface.didFinishNavigation(in: WKWebView(), paginationEngine: nil, colsPerScreen: .one)
        XCTAssertTrue(handled)
    }
}
