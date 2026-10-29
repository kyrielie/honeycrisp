//
//  SpeechSettingsTests.swift
//  HoneycrispTests
//
//  Created on 2026-10-28.
//

import Foundation
@testable import Honeycrisp
import XCTest

final class SpeechSettingsTests: XCTestCase {
    private var suiteName: String!
    private var testDefaults: UserDefaults!
    private var settings: SettingsManager!

    override func setUp() {
        super.setUp()
        suiteName = "SpeechSettingsTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsManager(defaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        settings = nil
        super.tearDown()
    }

    func testHighlightDefaultsAreOn() {
        XCTAssertTrue(settings.speechHighlight)
        XCTAssertTrue(settings.speechHighlightWord)
        XCTAssertTrue(settings.speechFollow)
    }

    func testHighlightSettingsPersist() {
        settings.speechHighlight = false
        settings.speechHighlightWord = false
        settings.speechFollow = false

        XCTAssertFalse(settings.speechHighlight)
        XCTAssertFalse(settings.speechHighlightWord)
        XCTAssertFalse(settings.speechFollow)

        let reloaded = SettingsManager(defaults: testDefaults)
        XCTAssertFalse(reloaded.speechHighlight)
        XCTAssertFalse(reloaded.speechHighlightWord)
        XCTAssertFalse(reloaded.speechFollow)
    }

    func testResetAllToDefaultsRestoresHighlight() {
        settings.speechHighlight = false
        settings.speechHighlightWord = false
        settings.speechFollow = false

        settings.resetAllToDefaults()

        XCTAssertTrue(settings.speechHighlight)
        XCTAssertTrue(settings.speechHighlightWord)
        XCTAssertTrue(settings.speechFollow)
    }
}
