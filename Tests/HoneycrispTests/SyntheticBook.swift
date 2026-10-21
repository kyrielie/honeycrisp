import Foundation

/// Generates a deterministic EPUB folder (EPUB 3 package, nested `Text/` and `Styles/`, one relative
/// image per chapter, a book stylesheet with class-only italics) of a requested nominal page count.
struct SyntheticBook {
    static let charactersPerPage = 1_800
    static let pagesPerChapter = 20
    static let paragraphCharacters = 300
    static let imageVariants = 8

    // 1x1 RGB PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    private static let words = [
        "the", "lantern", "burned", "low", "while", "she", "counted", "every", "step", "back", "toward", "home",
        "and", "nobody", "answered", "when", "he", "asked", "about", "the", "river", "&amp;", "its", "long", "memory",
    ]

    let pages: Int

    var chapterCount: Int { (pages + Self.pagesPerChapter - 1) / Self.pagesPerChapter }

    func write(to root: URL) throws {
        let fileManager = FileManager.default
        let oebps = root.appendingPathComponent("OEBPS", isDirectory: true)
        let text = oebps.appendingPathComponent("Text", isDirectory: true)
        let images = text.appendingPathComponent("Images", isDirectory: true)
        let styles = oebps.appendingPathComponent("Styles", isDirectory: true)
        let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
        for directory in [images, styles, metaInf] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(
            """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8
        ).write(to: metaInf.appendingPathComponent("container.xml"))
        try Data(".i { font-style: italic; } .fig { text-align: center; } .verse { text-align: center; }".utf8)
            .write(to: styles.appendingPathComponent("book.css"))
        for variant in 0..<Self.imageVariants {
            try Self.png.write(to: images.appendingPathComponent("fig\(variant).png"))
        }
        for chapter in 0..<chapterCount {
            try Data(chapterXHTML(index: chapter).utf8).write(to: text.appendingPathComponent("chapter\(chapter).xhtml"))
        }
        try Data(packageOPF().utf8).write(to: oebps.appendingPathComponent("package.opf"))
    }

    private func packageOPF() -> String {
        let chapters = (0..<chapterCount)
            .map { "<item id=\"c\($0)\" href=\"Text/chapter\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }
            .joined(separator: "\n    ")
        let spine = (0..<chapterCount).map { "<itemref idref=\"c\($0)\"/>" }.joined(separator: "\n    ")
        return """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Synthetic \(pages) pages</dc:title><dc:creator>Baseline</dc:creator><dc:language>en</dc:language>
              </metadata>
              <manifest>
                \(chapters)
                <item id="css" href="Styles/book.css" media-type="text/css"/>
              </manifest>
              <spine>
                \(spine)
              </spine>
            </package>
            """
    }

    private func chapterXHTML(index: Int) -> String {
        let pagesHere = min(Self.pagesPerChapter, pages - index * Self.pagesPerChapter)
        let paragraphCount = max(1, pagesHere * Self.charactersPerPage / Self.paragraphCharacters)
        let body = (0..<paragraphCount).map { paragraph(chapter: index, number: $0) }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Chapter \(index)</title>
            <link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
            <body><h2>Chapter \(index + 1)</h2>
            <p class="fig"><img src="Images/fig\(index % Self.imageVariants).png" alt=""/></p>
            \(body)
            </body></html>
            """
    }

    private func paragraph(chapter: Int, number: Int) -> String {
        var text = ""
        var cursor = chapter * 7 + number * 13
        while text.count < Self.paragraphCharacters {
            text += (text.isEmpty ? "" : " ") + Self.words[cursor % Self.words.count]
            cursor += 1
        }
        if number % 5 == 0 { return "<p><span class=\"i\">\(text)</span></p>" }
        if number % 11 == 0 { return "<p class=\"verse\">\(text)</p>" }
        return "<p>\(text)</p>"
    }
}
