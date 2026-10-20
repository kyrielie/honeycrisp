import Foundation
import XCTest
@testable import Honeycrisp

/// Counts the reader notifications `SettingsManager` posts, synchronously.
private final class NotificationCounter {
    private(set) var cosmetic = 0
    private(set) var structural = 0
    private(set) var general = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .readerCosmeticSettingsChanged, object: nil, queue: nil) { [weak self] _ in
            self?.cosmetic += 1
        })
        tokens.append(center.addObserver(forName: .readerStructuralSettingsChanged, object: nil, queue: nil) { [weak self] _ in
            self?.structural += 1
        })
        tokens.append(center.addObserver(forName: SettingsManager.settingsChangedNotification, object: nil, queue: nil) { [weak self] _ in
            self?.general += 1
        })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

final class SettingsManagerTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "SettingsManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFreshManagerHasNoOverrides() {
        let manager = SettingsManager(defaults: makeDefaults())
        XCTAssertEqual(manager.readerOverrides, .none)
        XCTAssertFalse(manager.hasReaderOverrides)
        XCTAssertFalse(manager.isReaderCustomized)
        XCTAssertEqual(manager.readerSkinID, "com.honeycrisp.original")
    }

    func testUpdatePersistsAndAnotherManagerReadsItBack() {
        let defaults = makeDefaults()
        SettingsManager(defaults: defaults).updateReaderOverrides {
            $0.fontSizePercent = 125
            $0.light.background = "#101010"
        }
        let reread = SettingsManager(defaults: defaults).readerOverrides
        XCTAssertEqual(reread.fontSizePercent, 125)
        XCTAssertEqual(reread.light.background, "#101010")
    }

    func testCosmeticChangePostsExactlyOneCosmeticAndOneGeneralNotification() {
        let manager = SettingsManager(defaults: makeDefaults())
        let counter = NotificationCounter()
        manager.updateReaderOverrides { $0.fontSizePercent = 120; $0.lineHeight = 1.9; $0.justify = true }
        XCTAssertEqual(counter.cosmetic, 1)
        XCTAssertEqual(counter.structural, 0)
        XCTAssertEqual(counter.general, 1)
    }

    func testGeometryChangePostsStructuralOnly() {
        let manager = SettingsManager(defaults: makeDefaults())
        let counter = NotificationCounter()
        manager.updateReaderOverrides { $0.maxWidth = 600 }
        XCTAssertEqual(counter.structural, 1)
        XCTAssertEqual(counter.cosmetic, 0)
        XCTAssertEqual(counter.general, 1)
    }

    func testNoOpUpdatePostsNothing() {
        let manager = SettingsManager(defaults: makeDefaults())
        manager.updateReaderOverrides { $0.fontSizePercent = 120 }
        let counter = NotificationCounter()
        manager.updateReaderOverrides { $0.fontSizePercent = 120 }
        manager.updateReaderOverrides { _ in }
        XCTAssertEqual(counter.cosmetic + counter.structural + counter.general, 0)
    }

    func testClearingEverythingRemovesTheStoredValue() {
        let defaults = makeDefaults()
        let manager = SettingsManager(defaults: defaults)
        manager.updateReaderOverrides { $0.lineHeight = 2 }
        XCTAssertNotNil(defaults.data(forKey: "readerOverrides.v1"))
        manager.clearReaderOverrides()
        XCTAssertNil(defaults.data(forKey: "readerOverrides.v1"))
        XCTAssertFalse(manager.hasReaderOverrides)
    }

    func testMalformedStoredJSONReadsAsNoOverrides() {
        let defaults = makeDefaults()
        defaults.set(Data("{not json".utf8), forKey: "readerOverrides.v1")
        XCTAssertEqual(SettingsManager(defaults: defaults).readerOverrides, .none)
    }

    func testStoredValuesAreSanitizedOnRead() throws {
        let defaults = makeDefaults()
        var hostile = ReaderOverrides()
        hostile.fontSizePercent = 100_000
        hostile.bodyFont = "}</style><script>"
        defaults.set(try JSONEncoder().encode(hostile), forKey: "readerOverrides.v1")
        let read = SettingsManager(defaults: defaults).readerOverrides
        XCTAssertEqual(read.fontSizePercent, 300)
        XCTAssertNil(read.bodyFont)
    }

    func testKeysFromEarlierBuildsAreIgnored() {
        let defaults = makeDefaults()
        defaults.set(200, forKey: "readerFontSizePercent")
        defaults.set(2.0, forKey: "readerLineHeight")
        defaults.set("Georgia, serif", forKey: "readerFontOverride")
        defaults.set("#123456", forKey: "readerBackgroundOverride")
        let manager = SettingsManager(defaults: defaults)
        XCTAssertEqual(manager.fontSizePercent, 100)
        XCTAssertEqual(manager.lineHeight, 1.6)
        XCTAssertEqual(manager.readerFontOverride, "")
        XCTAssertEqual(manager.readerBackgroundOverride, "")
    }

    func testCompatibilitySettersStoreBaselineValuesAsNil() {
        let manager = SettingsManager(defaults: makeDefaults())
        manager.lineHeight = 1.8
        XCTAssertEqual(manager.readerOverrides.lineHeight, 1.8)
        manager.lineHeight = ReaderBaseline.lineHeight
        XCTAssertNil(manager.readerOverrides.lineHeight)
        manager.justifyReaderText = true
        XCTAssertEqual(manager.readerOverrides.justify, true)
        manager.justifyReaderText = false
        XCTAssertNil(manager.readerOverrides.justify)
    }

    func testColorCompatibilitySettersWriteBothModes() {
        let manager = SettingsManager(defaults: makeDefaults())
        manager.readerBackgroundOverride = "#123456"
        XCTAssertEqual(manager.readerOverrides.light.background, "#123456")
        XCTAssertEqual(manager.readerOverrides.dark.background, "#123456")
        manager.readerBackgroundOverride = ""
        XCTAssertNil(manager.readerOverrides.light.background)
        XCTAssertNil(manager.readerOverrides.dark.background)
    }

    func testRemoveParagraphIndentsDoesNotWriteTheIndentOverride() {
        let manager = SettingsManager(defaults: makeDefaults())
        let counter = NotificationCounter()
        manager.removeParagraphIndents = true
        XCTAssertNil(manager.readerOverrides.paragraphIndent)
        XCTAssertEqual(manager.paragraphIndent, ReaderBaseline.paragraphIndent)
        XCTAssertEqual(counter.structural, 1)
        manager.removeParagraphIndents = false
        XCTAssertNil(manager.readerOverrides.paragraphIndent)
    }

    func testResetReaderToDefaultsPostsOneStructuralNotificationSet() {
        let manager = SettingsManager(defaults: makeDefaults())
        manager.readerSkinID = "com.honeycrisp.paper"
        manager.updateReaderOverrides { $0.fontSizePercent = 150; $0.maxWidth = 500; $0.light.ink = "#222222" }
        manager.removeParagraphIndents = true
        manager.allowReaderLinkClicks = false

        let counter = NotificationCounter()
        manager.resetReaderToDefaults()

        XCTAssertEqual(counter.structural, 1)
        XCTAssertEqual(counter.cosmetic, 0)
        XCTAssertEqual(counter.general, 1)
        XCTAssertEqual(manager.readerSkinID, "com.honeycrisp.original")
        XCTAssertEqual(manager.readerOverrides, .none)
        XCTAssertFalse(manager.removeParagraphIndents)
        XCTAssertTrue(manager.allowReaderLinkClicks)
        XCTAssertFalse(manager.isReaderCustomized)
    }
}
