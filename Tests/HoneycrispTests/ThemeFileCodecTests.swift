import XCTest
@testable import Honeycrisp

final class ThemeFileCodecTests: XCTestCase {

    func testRoundTripEncodingAndDecodingPreservesID() throws {
        let originalID = UUID()
        let theme = Theme(
            id: originalID,
            name: "Cozy Autumn",
            light: ThemeColorSet(background: "#fcfbf7", text: "#2c2825", link: "#8a532d"),
            dark: ThemeColorSet(background: "#1e1c1b", text: "#eae6e1", link: "#d4976a"),
            fontFamily: "Georgia, serif",
            fontSizePercent: 120,
            lineHeight: 1.75,
            maxWidth: 680,
            paddingH: 32,
            paddingV: 28,
            textAlignment: .left,
            hyphenate: true,
            paragraphSpacing: 1.5,
            paragraphIndent: 1.2,
            boldWeight: .bold,
            isDefault: false,
            seedKey: nil
        )

        let data = try ThemeFileCodec.encode(theme: theme)
        let decoded = try ThemeFileCodec.decode(data: data)

        XCTAssertEqual(decoded.id, originalID)
        XCTAssertEqual(decoded.name, "Cozy Autumn")
        XCTAssertEqual(decoded.light.background, "#fcfbf7")
        XCTAssertEqual(decoded.light.text, "#2c2825")
        XCTAssertEqual(decoded.dark.background, "#1e1c1b")
        XCTAssertEqual(decoded.fontFamily, "Georgia, serif")
        XCTAssertEqual(decoded.fontSizePercent, 120)
        XCTAssertEqual(decoded.lineHeight, 1.75)
        XCTAssertEqual(decoded.maxWidth, 680)
        XCTAssertEqual(decoded.paddingH, 32)
        XCTAssertEqual(decoded.paddingV, 28)
        XCTAssertEqual(decoded.textAlignment, .left)
        XCTAssertEqual(decoded.hyphenate, true)
        XCTAssertEqual(decoded.paragraphSpacing, 1.5)
        XCTAssertEqual(decoded.paragraphIndent, 1.2)
        XCTAssertEqual(decoded.boldWeight, .bold)
        XCTAssertFalse(decoded.isDefault)
        XCTAssertNil(decoded.seedKey)
    }

    func testSeedKeyHonoredOnlyIfRecognized() throws {
        let fakeSeed = Theme(
            name: "Hacker Theme",
            light: ThemeColorSet(background: "#000000", text: "#00ff00", link: "#00ff00"),
            dark: ThemeColorSet(background: "#000000", text: "#00ff00", link: "#00ff00"),
            isDefault: true,
            seedKey: "fake_seed_key"
        )
        let data = try ThemeFileCodec.encode(theme: fakeSeed)

        // Decode without valid seed key: should strip isDefault and seedKey
        let decodedUntrusted = try ThemeFileCodec.decode(data: data, validSeedKeys: ["original", "modern_light", "modern_dark"])
        XCTAssertFalse(decodedUntrusted.isDefault)
        XCTAssertNil(decodedUntrusted.seedKey)

        // Decode with matching valid seed key: should preserve
        let decodedTrusted = try ThemeFileCodec.decode(data: data, validSeedKeys: ["fake_seed_key"])
        XCTAssertTrue(decodedTrusted.isDefault)
        XCTAssertEqual(decodedTrusted.seedKey, "fake_seed_key")
    }

    func testCorruptDataOrUnsupportedVersionThrows() {
        let badJSON = Data("{\"notATheme\": true}".utf8)
        XCTAssertThrowsError(try ThemeFileCodec.decode(data: badJSON))

        let wrongVersionJSON = Data("{\"version\": 99, \"theme\": {}}".utf8)
        XCTAssertThrowsError(try ThemeFileCodec.decode(data: wrongVersionJSON))
    }

    func testSlugGeneration() {
        XCTAssertEqual(ThemeFileCodec.slug(for: "Simple Theme"), "Simple Theme")
        XCTAssertEqual(ThemeFileCodec.slug(for: "Theme / with : bad \\ chars"), "Theme  with  bad  chars")
        XCTAssertEqual(ThemeFileCodec.slug(for: "...Leading Dots"), "Leading Dots")
        XCTAssertEqual(ThemeFileCodec.slug(for: "   Trimming Whitespace   "), "Trimming Whitespace")
        XCTAssertEqual(ThemeFileCodec.slug(for: "///:::"), "Theme")
        XCTAssertEqual(ThemeFileCodec.slug(for: ""), "Theme")

        let veryLong = String(repeating: "A", count: 120)
        let slug = ThemeFileCodec.slug(for: veryLong)
        XCTAssertEqual(slug.count, 80)
    }

    func testFilenameWithCollisions() {
        XCTAssertEqual(ThemeFileCodec.filename(for: "Cozy"), "Cozy.honeycrisp-theme.json")
        XCTAssertEqual(ThemeFileCodec.filename(for: "Cozy", collisionIndex: 1), "Cozy.honeycrisp-theme.json")
        XCTAssertEqual(ThemeFileCodec.filename(for: "Cozy", collisionIndex: 2), "Cozy-2.honeycrisp-theme.json")
        XCTAssertEqual(ThemeFileCodec.filename(for: "Cozy", collisionIndex: 3), "Cozy-3.honeycrisp-theme.json")
    }
}
