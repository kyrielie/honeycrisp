import Foundation
import XCTest
@testable import Honeycrisp

final class EPUBParserTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneycrispTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testParsePackageFollowsContainerAndSpineOrder() throws {
        let root = try makeEPUBRoot(
            opfPath: "OEBPS/package.opf",
            opf: """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Test Book</dc:title><dc:creator>Test Author</dc:creator>
                <meta name="cover" content="cover-image"/>
              </metadata>
              <manifest>
                <item id="cover-image" href="Images/cover.jpg" media-type="image/jpeg"/>
                <item id="chapter-two" href="Text/chapter%202.xhtml" media-type="application/xhtml+xml"/>
                <item id="style" href="Styles/book.css" media-type="text/css"/>
                <item id="chapter-one" href="Text/chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="chapter-one"/><itemref idref="style"/><itemref idref="chapter-two"/></spine>
            </package>
            """,
            files: ["OEBPS/Images/cover.jpg", "OEBPS/Text/chapter1.xhtml", "OEBPS/Text/chapter 2.xhtml"]
        )

        let package = try EPUBParser().parsePackage(at: root)

        XCTAssertEqual(package.title, "Test Book")
        XCTAssertEqual(package.author, "Test Author")
        XCTAssertEqual(package.spineURLs.map(\.lastPathComponent), ["chapter1.xhtml", "chapter 2.xhtml"])
        XCTAssertEqual(package.coverURL?.lastPathComponent, "cover.jpg")
        XCTAssertEqual(package.spineURLs.first?.deletingLastPathComponent().lastPathComponent, "Text")
        XCTAssertEqual(package.version, "3.0")
        XCTAssertEqual(package.manifest["chapter-two"]?.mediaType, "application/xhtml+xml")
        XCTAssertEqual(package.spine.map(\.isLinear), [true, true])
    }

    func testManifestNavigationLandmarksAndNonLinearSpineAreRetained() throws {
        let root = try makeEPUBRoot(
            opfPath: "OPS/package.opf",
            opf: """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>  </dc:title><dc:creator> Author </dc:creator></metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="cover" linear="no"/><itemref idref="chapter"/></spine>
            </package>
            """,
            files: ["OPS/nav.xhtml", "OPS/cover.xhtml", "OPS/chapter.xhtml"]
        )
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="landmarks"><ol>
            <li><a href="chapter.xhtml#start" epub:type="bodymatter text">Start Reading</a></li>
          </ol></nav>
          <nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter</a></li></ol></nav>
        </body></html>
        """
        try Data(nav.utf8).write(to: root.appendingPathComponent("OPS/nav.xhtml"))

        let package = try EPUBParser().parsePackage(at: root)

        XCTAssertEqual(package.title, "")
        XCTAssertEqual(package.author, "Author")
        XCTAssertEqual(package.navigationURL?.lastPathComponent, "nav.xhtml")
        XCTAssertEqual(package.spine.map(\.isLinear), [false, true])
        XCTAssertEqual(package.landmarks.map(\.type), ["bodymatter", "text"])
        XCTAssertEqual(package.landmarks.first?.url.fragment, "start")
    }

    func testSearchResultsRetainChapterAndUTF16TextOffsets() throws {
        let root = try makeEPUBRoot(
            opfPath: "package.opf",
            opf: """
            <package><metadata><title>Search</title></metadata><manifest>
              <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="one"/></spine></package>
            """,
            files: ["one.xhtml"]
        )
        try Data("<html><body><p>😀 before &amp; after Needle.</p></body></html>".utf8).write(to: root.appendingPathComponent("one.xhtml"))
        let package = try EPUBParser().parsePackage(at: root)

        let results = EPUBParser().searchResults(for: "needle", in: package)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.spineIndex, 0)
        XCTAssertEqual(results.first?.characterOffset, 18)
        XCTAssertTrue(results.first?.excerpt.contains("Needle") == true)
    }

    func testJavaScriptStringLiteralEscapesExecutableInput() throws {
        let input = "x'); alert(1); // \\\n \" \u{2028}"

        let literal = try XCTUnwrap(EPUBParser.javaScriptStringLiteral(input))

        XCTAssertTrue(literal.hasPrefix("\""))
        XCTAssertTrue(literal.hasSuffix("\""))
        XCTAssertFalse(literal.contains("\n"))
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        XCTAssertEqual(decoded, input)
    }

    func testParsePackageRejectsAnEmptyOrNonHTMLSpine() throws {
        let root = try makeEPUBRoot(
            opfPath: "package.opf",
            opf: """
            <package><metadata><title>Empty</title></metadata>
              <manifest><item id="image" href="cover.jpg" media-type="image/jpeg"/></manifest>
              <spine><itemref idref="image"/></spine>
            </package>
            """
        )

        XCTAssertThrowsError(try EPUBParser().parsePackage(at: root)) { error in
            guard let parseError = error as? EPUBParseError else {
                return XCTFail("Expected EPUBParseError, got \(error)")
            }
            guard case .malformed = parseError else {
                return XCTFail("Expected malformed EPUB error, got \(parseError)")
            }
        }
    }

    func testDRMErrorTakesPrecedenceOverMissingContainer() throws {
        // D3: an empty <encryption/> is no longer DRM, so this uses an ADEPT marker to keep the
        // precedence assertion (DRM is reported before the missing container/OPF).
        let root = temporaryDirectory.appendingPathComponent("drm", isDirectory: true)
        let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        let xml = encryptionXML(encryptedData(algorithm: Self.fontAlgorithm, keyInfo: Self.adeptKeyInfo))
        try Data(xml.utf8).write(to: metaInf.appendingPathComponent("encryption.xml"))

        assertDRMProtected(root)
    }

    func testEmptyEncryptionManifestWithNoContainerIsNotDRM() throws {
        let root = temporaryDirectory.appendingPathComponent("empty-encryption", isDirectory: true)
        let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try Data("<encryption/>".utf8).write(to: metaInf.appendingPathComponent("encryption.xml"))

        XCTAssertThrowsError(try EPUBParser().parsePackage(at: root)) { error in
            guard let parseError = error as? EPUBParseError, case .opfNotFound = parseError else {
                return XCTFail("Expected opfNotFound (not DRM), got \(error)")
            }
        }
    }

    func testFontObfuscationOnlyEncryptionManifestOpensNormally() throws {
        let xml = encryptionXML(
            encryptedData(algorithm: "http://www.idpf.org/2008/embedding"),
            encryptedData(algorithm: "http://ns.adobe.com/pdf/enc#RC"))
        let root = try makeReadableRoot(encryptionXML: xml)

        let package = try EPUBParser().parsePackage(at: root)

        XCTAssertEqual(package.title, "Fonts Only")
        XCTAssertEqual(package.spineURLs.map(\.lastPathComponent), ["chapter.xhtml"])
    }

    func testADEPTResourceMarkerIsDRMEvenWithFontAlgorithm() throws {
        let xml = encryptionXML(encryptedData(algorithm: Self.fontAlgorithm, keyInfo: Self.adeptKeyInfo))
        assertDRMProtected(try makeReadableRoot(encryptionXML: xml))
    }

    func testLCPRetrievalMethodMarkerIsDRMEvenWithFontAlgorithm() throws {
        let keyInfo =
            "<ds:KeyInfo><ds:RetrievalMethod URI=\"license.lcpl#/encryption/content_key\" "
            + "Type=\"http://readium.org/2014/01/lcp#EncryptedContentKey\"/></ds:KeyInfo>"
        let xml = encryptionXML(encryptedData(algorithm: Self.fontAlgorithm, keyInfo: keyInfo))
        assertDRMProtected(try makeReadableRoot(encryptionXML: xml))
    }

    func testLCPLicenseFileIsDRM() throws {
        let root = try makeReadableRoot(encryptionXML: nil)
        let license = root.appendingPathComponent("META-INF/license.lcpl")
        try Data("{}".utf8).write(to: license)

        assertDRMProtected(root)
    }

    func testUnknownEncryptionAlgorithmIsDRM() throws {
        let xml = encryptionXML(
            encryptedData(algorithm: "http://www.w3.org/2001/04/xmlenc#aes128-cbc"))
        assertDRMProtected(try makeReadableRoot(encryptionXML: xml))
    }

    func testEncryptionMethodWithoutAlgorithmIsTreatedAsDRM() throws {
        let xml = encryptionXML("<enc:EncryptedData><enc:EncryptionMethod/></enc:EncryptedData>")
        assertDRMProtected(try makeReadableRoot(encryptionXML: xml))
    }

    func testUnparseableEncryptionManifestIsNotDRM() throws {
        let root = try makeReadableRoot(encryptionXML: "<<< not xml")

        XCTAssertEqual(try EPUBParser().parsePackage(at: root).title, "Fonts Only")
    }

    func testParsePackageFindsOPFWhenContainerIsMissing() throws {
        let root = try makeEPUBRoot(
            opfPath: "OPS/content.opf",
            includeContainer: false,
            opf: """
            <package><metadata><title>Fallback</title></metadata>
              <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """,
            files: ["OPS/chapter.xhtml"]
        )

        let package = try EPUBParser().parsePackage(at: root)

        XCTAssertEqual(package.title, "Fallback")
        XCTAssertEqual(package.spineURLs.map(\.lastPathComponent), ["chapter.xhtml"])
    }

    func testUnpackEPUBCopiesAnExtractedDirectoryIntoOwnedWorkDirectory() throws {
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("chapter".utf8).write(to: source.appendingPathComponent("chapter.xhtml"))
        let work = temporaryDirectory.appendingPathComponent("work", isDirectory: true)

        let unpacked = try EPUBParser().unpackEPUB(at: source, to: work)

        XCTAssertEqual(unpacked.lastPathComponent, "EPUBPackage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("chapter.xhtml").path))
    }

    private static let fontAlgorithm = "http://www.idpf.org/2008/embedding"
    private static let adeptKeyInfo =
        "<ds:KeyInfo><ds:resource xmlns:adept=\"http://ns.adobe.com/adept\">urn:uuid:test</ds:resource>"
        + "</ds:KeyInfo>"

    private func encryptedData(algorithm: String, keyInfo: String = "") -> String {
        "<enc:EncryptedData><enc:EncryptionMethod Algorithm=\"\(algorithm)\"/>\(keyInfo)"
            + "<enc:CipherData><enc:CipherReference URI=\"OPS/a.otf\"/></enc:CipherData></enc:EncryptedData>"
    }

    private func encryptionXML(_ bodies: String...) -> String {
        "<?xml version=\"1.0\"?><encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" "
            + "xmlns:enc=\"http://www.w3.org/2001/04/xmlenc#\" "
            + "xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\">\(bodies.joined())</encryption>"
    }

    /// A package that parses on its own, optionally with a META-INF/encryption.xml.
    private func makeReadableRoot(encryptionXML: String?) throws -> URL {
        let root = try makeEPUBRoot(
            opfPath: "OPS/content.opf",
            opf: """
                <package><metadata><title>Fonts Only</title></metadata>
                  <manifest>
                    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="chapter"/></spine>
                </package>
                """,
            files: ["OPS/chapter.xhtml"]
        )
        if let encryptionXML {
            let url = root.appendingPathComponent("META-INF/encryption.xml")
            try Data(encryptionXML.utf8).write(to: url)
        }
        return root
    }

    private func assertDRMProtected(_ root: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EPUBParser().parsePackage(at: root), file: file, line: line) { error in
            guard let parseError = error as? EPUBParseError else {
                return XCTFail("Expected EPUBParseError, got \(error)", file: file, line: line)
            }
            guard case .drmProtected = parseError else {
                return XCTFail("Expected DRM-protected EPUB error, got \(parseError)", file: file, line: line)
            }
        }
    }

    private func makeEPUBRoot(
        opfPath: String,
        includeContainer: Bool = true,
        opf: String,
        files: [String] = []
    ) throws -> URL {
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let opfURL = root.appendingPathComponent(opfPath)
        try FileManager.default.createDirectory(
            at: opfURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(opf.utf8).write(to: opfURL)

        for path in files {
            let fileURL = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: fileURL)
        }

        if includeContainer {
            let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
            try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
            let container = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
            try Data(container.utf8).write(to: metaInf.appendingPathComponent("container.xml"))
        }
        return root
    }
}
