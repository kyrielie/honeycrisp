import XCTest
@testable import Honeycrisp

final class ChapterDecoderTests: XCTestCase {
    func testUTF8BOMIsStrippedAndReported() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("Hello world".utf8))
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .bom)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertFalse(result.text.contains("\u{FEFF}"))
    }

    func testUTF16LittleEndianBOMDecodes() {
        var data = Data([0xFF, 0xFE])
        data.append("caf\u{e9}".data(using: .utf16LittleEndian)!)
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .bom)
        XCTAssertEqual(result.text, "caf\u{e9}")
    }

    func testXMLDeclarationLatin1Decodes() {
        let header = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><body>caf"
        var data = header.data(using: .isoLatin1)!
        data.append(0xE9)
        data.append("</body>".data(using: .isoLatin1)!)
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .xmlDeclaration)
        XCTAssertTrue(result.text.contains("caf\u{e9}"))
    }

    func testMetaCharsetWindows1252Decodes() {
        let prefix = "<html><head><meta charset=\"windows-1252\"></head><body>"
        var data = prefix.data(using: .ascii)!
        data.append(contentsOf: [0x93, 0x94])
        data.append("</body></html>".data(using: .ascii)!)
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .metaCharset)
        XCTAssertTrue(result.text.contains("\u{201C}\u{201D}"))
    }

    func testHttpEquivContentTypeDecodes() {
        let prefix = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\"></head><body>caf"
        var data = prefix.data(using: .isoLatin1)!
        data.append(0xE9)
        data.append("</body></html>".data(using: .isoLatin1)!)
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .metaCharset)
        XCTAssertTrue(result.text.contains("caf\u{e9}"))
    }

    func testInvalidUTF8WithNoLabelFallsBackToWindows1252() {
        let data = Data([0x93, 0x94])
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .windows1252)
        XCTAssertEqual(result.text, "\u{201C}\u{201D}")
    }

    func testBOMWinsOverConflictingMeta() {
        var data = Data([0xEF, 0xBB, 0xBF])
        let content = "<html><head><meta charset=\"windows-1252\"></head><body>Plain UTF8</body></html>"
        data.append(Data(content.utf8))
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .bom)
        XCTAssertTrue(result.text.contains("Plain UTF8"))
    }

    func testUnknownLabelIsIgnoredAndUTF8Used() {
        let content = "<html><head><meta charset=\"unknown-custom-encoding\"></head><body>Valid UTF-8 \u{e9}</body></html>"
        let data = Data(content.utf8)
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .utf8)
        XCTAssertTrue(result.text.contains("Valid UTF-8 \u{e9}"))
    }

    func testPlainUTF8ReportsUtf8() {
        let content = "<p>Simple text without declarations</p>"
        let data = Data(content.utf8)
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .utf8)
        XCTAssertEqual(result.text, content)
    }

    func testMetaBeyondFirstKilobyteIsIgnored() {
        let padding = String(repeating: " ", count: 1050)
        let content = "<!--\(padding)--><meta charset=\"windows-1252\">"
        var data = content.data(using: .ascii)!
        data.append(contentsOf: [0x93, 0x94])
        let result = ChapterDecoder.decode(data)
        XCTAssertEqual(result.source, .windows1252)
        XCTAssertTrue(result.text.contains("\u{201C}\u{201D}"))
    }
}
