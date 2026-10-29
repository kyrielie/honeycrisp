import XCTest
@testable import Honeycrisp

final class ThemeStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ThemeStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testInitialLaunchPopulatesMissingSeedThemes() throws {
        let store = ThemeStore(directoryURL: tempDirectory)
        XCTAssertFalse(store.themes.isEmpty)
        XCTAssertGreaterThanOrEqual(store.themes.count, 3)

        // Seed files should now exist on disk
        let files = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        let themeFiles = files.filter { $0.lastPathComponent.hasSuffix(ThemeFileCodec.fileExtension) }
        XCTAssertGreaterThanOrEqual(themeFiles.count, 3)
    }

    func testSaveCustomThemeWritesFileAtomically() throws {
        let store = ThemeStore(directoryURL: tempDirectory)
        let customTheme = Theme(
            name: "Mint Fresh",
            light: ThemeColorSet(background: "#f0fff0", text: "#103010", link: "#208020"),
            dark: ThemeColorSet(background: "#102010", text: "#d0ffd0", link: "#40c040")
        )

        var themes = store.themes
        themes.append(customTheme)
        store.setThemes(themes, debounce: false)

        let targetFile = tempDirectory.appendingPathComponent("Mint Fresh.honeycrisp-theme.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))

        let data = try Data(contentsOf: targetFile)
        let decoded = try ThemeFileCodec.decode(data: data)
        XCTAssertEqual(decoded.id, customTheme.id)
        XCTAssertEqual(decoded.name, "Mint Fresh")
    }

    func testRenamingThemeCleansUpOldFile() throws {
        let store = ThemeStore(directoryURL: tempDirectory)
        var customTheme = Theme(
            name: "Original Name",
            light: ThemeColorSet(background: "#ffffff", text: "#000000", link: "#0000ff"),
            dark: ThemeColorSet(background: "#000000", text: "#ffffff", link: "#00ffff")
        )

        store.setThemes(store.themes + [customTheme], debounce: false)
        let oldFile = tempDirectory.appendingPathComponent("Original Name.honeycrisp-theme.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))

        // Rename
        customTheme.name = "New Shiny Name"
        var updated = store.themes.filter { $0.id != customTheme.id }
        updated.append(customTheme)
        store.setThemes(updated, debounce: false)

        let newFile = tempDirectory.appendingPathComponent("New Shiny Name.honeycrisp-theme.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
    }

    func testSlugCollisionDisambiguation() throws {
        let store = ThemeStore(directoryURL: tempDirectory)
        let theme1 = Theme(
            name: "Duplicate Name",
            light: ThemeColorSet(background: "#ffffff", text: "#000000", link: "#0000ff"),
            dark: ThemeColorSet(background: "#000000", text: "#ffffff", link: "#00ffff")
        )
        let theme2 = Theme(
            name: "Duplicate Name",
            light: ThemeColorSet(background: "#eeeeee", text: "#111111", link: "#1111ff"),
            dark: ThemeColorSet(background: "#111111", text: "#eeeeee", link: "#11ffff")
        )

        store.setThemes(store.themes + [theme1, theme2], debounce: false)

        let file1 = tempDirectory.appendingPathComponent("Duplicate Name.honeycrisp-theme.json")
        let file2 = tempDirectory.appendingPathComponent("Duplicate Name-2.honeycrisp-theme.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))
    }

    func testDeleteCustomThemeRemovesFile() throws {
        let store = ThemeStore(directoryURL: tempDirectory)
        let customTheme = Theme(
            name: "Temporary",
            light: ThemeColorSet(background: "#ffffff", text: "#000000", link: "#0000ff"),
            dark: ThemeColorSet(background: "#000000", text: "#ffffff", link: "#00ffff")
        )

        store.setThemes(store.themes + [customTheme], debounce: false)
        let file = tempDirectory.appendingPathComponent("Temporary.honeycrisp-theme.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        store.setThemes(store.themes.filter { $0.id != customTheme.id }, debounce: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCorruptFileIsPreservedAndNotDeleted() throws {
        let store = ThemeStore(directoryURL: tempDirectory)
        let corruptFile = tempDirectory.appendingPathComponent("Corrupted.honeycrisp-theme.json")
        try "not json at all".write(to: corruptFile, atomically: true, encoding: .utf8)

        // Rescan
        store.rescanIfChanged()

        // File should still exist on disk untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptFile.path))
    }
}
