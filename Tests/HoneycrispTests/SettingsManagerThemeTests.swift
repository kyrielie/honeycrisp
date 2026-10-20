import Foundation
import XCTest
@testable import Honeycrisp

/// Covers theme identity, migration and reset. Uses an isolated UserDefaults suite per test, so the
/// app's real settings are never read or written. Nothing here touches NSApp.
final class SettingsManagerThemeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var manager: SettingsManager!

    override func setUp() {
        super.setUp()
        suiteName = "HoneycrispTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        manager = SettingsManager(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        manager = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: Seeds

    func testSeedThemesHaveUniqueKeysAndAreDefault() {
        let keys = SettingsManager.seedThemes.compactMap(\.seedKey)
        XCTAssertEqual(keys.count, SettingsManager.seedThemes.count)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(SettingsManager.seedThemes.allSatisfy(\.isDefault))
    }

    func testFreshInstallIsNotCustomized() {
        XCTAssertEqual(manager.themes.map(\.seedKey), SettingsManager.seedThemes.map(\.seedKey))
        XCTAssertFalse(manager.isReaderCustomized)
    }

    // MARK: Codable

    func testSeedKeyRoundTrips() throws {
        let theme = SettingsManager.seedThemes[0]
        let decoded = try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme))
        XCTAssertEqual(decoded.seedKey, theme.seedKey)
        XCTAssertEqual(decoded, theme)
    }

    func testLegacyThemeJSONWithoutSeedKeyDecodesAsNil() throws {
        var legacy = SettingsManager.seedThemes[0]
        legacy.seedKey = nil
        let data = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(Theme.self, from: data).seedKey)
    }

    func testTextAlignmentAndHyphenationRoundTripAndReset() throws {
        manager.textAlignment = .justify
        manager.hyphenate = true
        manager.paragraphSpacing = 2.25
        manager.paragraphIndent = 1.5
        manager.boldWeight = .medium
        let theme = try XCTUnwrap(manager.themes.first)
        let decoded = try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme))
        XCTAssertEqual(decoded.textAlignment, .justify)
        XCTAssertTrue(decoded.hyphenate)
        XCTAssertEqual(decoded.paragraphSpacing, 2.25)
        XCTAssertEqual(decoded.paragraphIndent, 1.5)
        XCTAssertEqual(decoded.boldWeight, .medium)
        XCTAssertTrue(manager.isReaderCustomized)

        manager.resetReaderToDefaults()
        XCTAssertEqual(manager.textAlignment, .book)
        XCTAssertFalse(manager.hyphenate)
        XCTAssertEqual(manager.paragraphSpacing, 1.0)
        XCTAssertNil(manager.paragraphIndent)
        XCTAssertEqual(manager.boldWeight, .book)
        XCTAssertFalse(manager.isReaderCustomized)
    }

    func testThemeExportImportsAsSanitizedCustomCopy() throws {
        var source = SettingsManager.seedThemes[0]
        source.fontFamily = "bad); color:red"
        source.light.text = "url(javascript:bad)"
        source.paragraphSpacing = 99
        source.paragraphIndent = 99
        let imported = try ThemeExport.decode(ThemeExport.encode(source))
        XCTAssertNotEqual(imported.id, source.id)
        XCTAssertFalse(imported.isDefault)
        XCTAssertNil(imported.seedKey)
        XCTAssertEqual(imported.fontFamily, FontPresets.defaultStack)
        XCTAssertEqual(imported.light.text, ReaderCSSSanitizer.fallbackText)
        XCTAssertEqual(imported.paragraphSpacing, 3.0)
        XCTAssertEqual(imported.paragraphIndent, 4.0)
    }

    // MARK: Reset by identity, not name

    func testRenamedDefaultThemeIsRestoredInPlaceNotDuplicated() {
        var list = manager.themes
        let paperIndex = list.firstIndex { $0.seedKey == "paper" }!
        let paperID = list[paperIndex].id
        list[paperIndex].name = "Sepia"
        list[paperIndex].light.background = "#123456"
        manager.themes = list

        XCTAssertTrue(manager.isReaderCustomized)
        manager.resetReaderToDefaults()

        let after = manager.themes
        XCTAssertEqual(after.count, SettingsManager.seedThemes.count)
        let paper = after.first { $0.seedKey == "paper" }
        XCTAssertEqual(paper?.id, paperID)
        XCTAssertEqual(paper?.name, "Paper")
        XCTAssertEqual(paper?.light, SettingsManager.seedThemes.first { $0.seedKey == "paper" }?.light)
        XCTAssertFalse(manager.isReaderCustomized)
    }

    func testResetRestoresDeletedDefaultOnce() {
        var list = manager.themes
        list.removeAll { $0.seedKey == "quiet" }
        manager.themes = list

        XCTAssertTrue(manager.isReaderCustomized)
        manager.resetReaderToDefaults()
        XCTAssertEqual(manager.themes.filter { $0.seedKey == "quiet" }.count, 1)
        manager.resetReaderToDefaults()
        XCTAssertEqual(manager.themes.filter { $0.seedKey == "quiet" }.count, 1)
    }

    // MARK: Migration

    func testBackfillGivesSeedKeyToNamedDefaultsAndDemotesRenamedOnes() {
        var named = SettingsManager.seedThemes[2]
        named.seedKey = nil
        var renamed = SettingsManager.seedThemes[1]
        renamed.seedKey = nil
        renamed.name = "Mine"

        let result = SettingsManager.backfillSeedKeys([named, renamed])
        XCTAssertEqual(result[0].seedKey, "paper")
        XCTAssertTrue(result[0].isDefault)
        XCTAssertNil(result[1].seedKey)
        XCTAssertFalse(result[1].isDefault)

        // Idempotent: a second pass changes nothing.
        XCTAssertEqual(SettingsManager.backfillSeedKeys(result), result)
    }

    func testStoredPreSeedKeyThemesAreMigratedOnRead() throws {
        var named = SettingsManager.seedThemes[0]
        named.seedKey = nil
        let data = try JSONEncoder().encode([named])
        defaults.set(data, forKey: "readerThemes")

        let themes = manager.themes
        XCTAssertEqual(themes.first?.seedKey, "original")
        // Persisted, so the migration does not run again.
        let stored = try JSONDecoder().decode([Theme].self, from: XCTUnwrap(defaults.data(forKey: "readerThemes")))
        XCTAssertEqual(stored.first?.seedKey, "original")
    }

    // MARK: Delete protection

    func testDefaultThemesCannotBeDeleted() {
        let paper = manager.themes.first { $0.seedKey == "paper" }!
        manager.deleteTheme(paper.id)
        XCTAssertNotNil(manager.themes.first { $0.id == paper.id })
    }
}
