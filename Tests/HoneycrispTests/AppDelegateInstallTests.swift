import AppKit
import XCTest
@testable import Honeycrisp

@MainActor
final class AppDelegateInstallTests: XCTestCase {
    func testApplicationDelegateIsAppDelegate() {
        XCTAssertNotNil(NSApp.delegate, "NSApp.delegate must not be nil at runtime")
        XCTAssertTrue(NSApp.delegate is AppDelegate, "NSApp.delegate must be an instance of AppDelegate")
    }
}
