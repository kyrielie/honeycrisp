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
        let root = temporaryDirectory.appendingPathComponent("drm", isDirectory: true)
        let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try Data("<encryption/>".utf8).write(to: metaInf.appendingPathComponent("encryption.xml"))

        XCTAssertThrowsError(try EPUBParser().parsePackage(at: root)) { error in
            guard let parseError = error as? EPUBParseError else {
                return XCTFail("Expected EPUBParseError, got \(error)")
            }
            guard case .drmProtected = parseError else {
                return XCTFail("Expected DRM-protected EPUB error, got \(parseError)")
            }
        }
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
