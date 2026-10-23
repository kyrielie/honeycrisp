import XCTest
@testable import Honeycrisp

final class NavigationHistoryTests: XCTestCase {
    func testEmptyStackCannotNavigate() {
        var stack = NavigationHistoryStack<NavigationLocation>()
        XCTAssertFalse(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)
        XCTAssertNil(stack.goBack(current: NavigationLocation(resource: 0, offset: 10)))
        XCTAssertNil(stack.goForward(current: NavigationLocation(resource: 0, offset: 10)))
    }

    func testPushAndGoBack() {
        var stack = NavigationHistoryStack<NavigationLocation>()
        let loc1 = NavigationLocation(resource: 0, offset: 50)
        let loc2 = NavigationLocation(resource: 1, offset: 200)

        stack.push(loc1)
        XCTAssertTrue(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)

        let target = stack.goBack(current: loc2)
        XCTAssertEqual(target, loc1)
        XCTAssertFalse(stack.canGoBack)
        XCTAssertTrue(stack.canGoForward)

        let forwardTarget = stack.goForward(current: loc1)
        XCTAssertEqual(forwardTarget, loc2)
        XCTAssertTrue(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)
    }

    func testPushClearsForwardStack() {
        var stack = NavigationHistoryStack<NavigationLocation>()
        let loc1 = NavigationLocation(resource: 0, offset: 10)
        let loc2 = NavigationLocation(resource: 1, offset: 20)
        let loc3 = NavigationLocation(resource: 2, offset: 30)

        stack.push(loc1)
        _ = stack.goBack(current: loc2)
        XCTAssertTrue(stack.canGoForward)

        stack.push(loc3)
        XCTAssertFalse(stack.canGoForward)
        XCTAssertTrue(stack.canGoBack)
    }

    func testDuplicateSuppression() {
        var stack = NavigationHistoryStack<NavigationLocation>()
        let loc1 = NavigationLocation(resource: 0, offset: 100)

        stack.push(loc1)
        stack.push(loc1)
        XCTAssertEqual(stack.backStack.count, 1)

        let loc2 = NavigationLocation(resource: 1, offset: 50)
        _ = stack.goBack(current: loc2)
        _ = stack.goForward(current: loc1)
        XCTAssertEqual(stack.forwardStack.count, 0)
    }

    func testCapacityLimit() {
        var stack = NavigationHistoryStack<Int>(maxCapacity: 3)
        stack.push(1)
        stack.push(2)
        stack.push(3)
        stack.push(4)

        XCTAssertEqual(stack.backStack.count, 3)
        XCTAssertEqual(stack.backStack, [2, 3, 4])
    }

    func testClearResetsBothStacks() {
        var stack = NavigationHistoryStack<NavigationLocation>()
        stack.push(NavigationLocation(resource: 0, offset: 10))
        _ = stack.goBack(current: NavigationLocation(resource: 1, offset: 20))
        XCTAssertTrue(stack.canGoForward)

        stack.clear()
        XCTAssertFalse(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)
        XCTAssertTrue(stack.backStack.isEmpty)
        XCTAssertTrue(stack.forwardStack.isEmpty)
    }

    func testNavigationLocationClampsNegatives() {
        let loc = NavigationLocation(resource: -5, offset: -100)
        XCTAssertEqual(loc.resource, 0)
        XCTAssertEqual(loc.offset, 0)
    }
}
