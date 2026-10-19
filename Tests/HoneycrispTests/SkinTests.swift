import Foundation
import XCTest
@testable import Honeycrisp

final class SkinTests: XCTestCase {
    private let validTemplate = #"<div id="bodyContainer" class="articleBody">[[title]][[body]]</div>"#

    func testValidTokensAndContrast() throws {
        let result = try SkinValidator.validate(css: #":root{--nnw-bg:#fff;--nnw-ink:#000;--nnw-link:#06c;}"#, template: validTemplate)
        XCTAssertEqual(result.light?.background, "#fff")
        XCTAssertEqual(result.dark?.ink, "#000")
        XCTAssertFalse(result.usesDefaultColors)
        XCTAssertFalse(result.lowContrast)
        XCTAssertEqual(SkinValidator.contrast("#000", "#fff"), 21, accuracy: 0.01)
    }

    func testSingleSchemeAndTokenlessSkinsAreAccepted() throws {
        let single = try SkinValidator.validate(css: #":root{--nnw-bg:#fff;--nnw-ink:#000;--nnw-link:#06c;}"#, template: validTemplate)
        XCTAssertEqual(single.dark, single.light)
        let tokenless = try SkinValidator.validate(css: "body{color:#123}", template: validTemplate)
        XCTAssertTrue(tokenless.usesDefaultColors)
    }

    func testDarkTokensAreReadFromNestedMediaRootBlock() throws {
        let css = #":root{--nnw-bg:#ffffff;--nnw-ink:#000000;--nnw-link:#0068da;}@media (prefers-color-scheme: dark){:root{--nnw-bg:#1d232d;--nnw-ink:#e4e7ec;--nnw-link:#91b7d8;--fx-box:#29313f;}}"#
        let result = try SkinValidator.validate(css: css, template: validTemplate)
        XCTAssertEqual(result.light?.background, "#ffffff")
        XCTAssertEqual(result.dark?.background, "#1d232d")
        XCTAssertEqual(result.dark?.ink, "#e4e7ec")
        XCTAssertEqual(result.dark?.link, "#91b7d8")
        XCTAssertTrue(result.css.contains("--fx-box:#29313f"))
    }

    func testTokenlessDarkSkinCanInferItsLiteralBodyPalette() throws {
        let css = #":root{color-scheme:dark;--rv-bg:#333;--rv-text:#eee;--rv-link:#fff;}body{background-color:#333;color:#eee;}a{color:#fff;}"#
        let result = try SkinValidator.validate(css: css, template: validTemplate)
        XCTAssertEqual(result.light?.background, "#333")
        XCTAssertEqual(result.light?.ink, "#eee")
        XCTAssertEqual(result.light?.link, "#fff")
        XCTAssertEqual(result.dark, result.light)
        XCTAssertFalse(result.usesDefaultColors)
    }

    func testMalformedTokenAndLowContrastAreRejected() {
        XCTAssertThrowsError(try SkinValidator.validate(css: #":root{--nnw-bg:red;--nnw-ink:#000;--nnw-link:#06c;}"#, template: validTemplate))
        XCTAssertThrowsError(try SkinValidator.validate(css: #":root{--nnw-bg:#fff;--nnw-ink:#f0f0f0;--nnw-link:#06c;}"#, template: validTemplate))
    }

    func testCSSImportsAreRemovedAndWebFontsRecorded() throws {
        let css = #"@import url('https://fonts.googleapis.com/css2?family=Fixture:wght@400;600&display=swap'); :root{--nnw-bg:#fff;--nnw-ink:#000;--nnw-link:#06c;}"#
        let result = try SkinValidator.validate(css: css, template: validTemplate)
        XCTAssertFalse(result.css.contains("@import"))
        XCTAssertEqual(result.fontImports, ["Fixture:wght@400;600"])
    }

    func testAO3PrefaceSkinRulesAlsoMatchNativeEPUBPreface() throws {
        let css = #".t430 #ao3Preface,.t430 #ao3SyntheticPreface{border:1px solid red}#ao3Preface dt{font-weight:bold}"#
        let result = try SkinValidator.validate(css: css, template: validTemplate)
        XCTAssertTrue(result.css.contains(".t430 :is(#ao3Preface, #preface)"))
        XCTAssertTrue(result.css.contains(":is(#ao3Preface, #preface) dt"))
        XCTAssertTrue(result.css.contains("#ao3SyntheticPreface"))
    }

    func testTemplateRendererStripsCommentsScriptsAndUnknownMacros() {
        let source = #"<!-- [[title]] --><script>ignored()</script><div id="bodyContainer" class="articleBody"><h1>[[title]]</h1>[[body]][[unknown]]</div>"#
        let result = SkinTemplate.render(source, body: "<p>Story</p>", title: "A & B", author: "Writer", sourceURL: nil, siteLabel: nil)
        XCTAssertFalse(result.contains("ignored"))
        XCTAssertFalse(result.contains("unknown"))
        XCTAssertTrue(result.contains("A &amp; B"))
        XCTAssertTrue(result.contains("<p>Story</p>"))
    }

    func testUnsafeTemplateFallsBackToMinimalTemplate() {
        let source = #"<div id="bodyContainer" class="articleBody" onclick="x()">[[body]]</div>"#
        XCTAssertEqual(SkinTemplate.sanitize(source), SkinTemplate.defaultTemplate)
        XCTAssertEqual(SkinTemplate.sanitize(#"<div id="bodyContainer" class="articleBody"><iframe></iframe>[[body]]</div>"#), SkinTemplate.defaultTemplate)
    }

    func testBundledSkinsLoadThroughTheSameValidatorAsImports() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("Sources/Skins/Bundled", isDirectory: true)
        for name in ["Original", "Quiet", "Paper", "Fimfiction"] {
            let skin = try SkinLoader.load(directory: root.appendingPathComponent(name + ".nnwtheme", isDirectory: true))
            XCTAssertTrue(skin.id.hasPrefix("com.honeycrisp."))
        }
    }

    func testFimfictionCanvasUsesPageTokenAndPreservesArticleBoxToken() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skin = try SkinLoader.load(directory: repository.appendingPathComponent("Sources/Skins/Bundled/Fimfiction.nnwtheme", isDirectory: true))
        XCTAssertTrue(skin.css.contains("--nnw-bg"))
        XCTAssertTrue(skin.css.contains("--fx-box"))
        XCTAssertFalse(skin.css.contains("html, body"))
    }

    func testRemoteCSSURLsAndUnsafeLayoutRulesAreRejected() {
        XCTAssertThrowsError(try SkinValidator.validate(css: "body{background:url(https://example.com/a.png)}", template: validTemplate))
        XCTAssertThrowsError(try SkinValidator.validate(css: "body{height:100%}", template: validTemplate))
    }
}
