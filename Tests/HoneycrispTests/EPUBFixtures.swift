import Foundation

/// Builds minimal on-disk EPUB roots whose spine items carry real content, for tests that exercise
/// `EPUBParser.extractedChapterBody`, search and speech. `EPUBParserTests.makeEPUBRoot` writes empty
/// files, so it cannot be used for those. All content is synthetic; never add real EPUBs to the repo.
enum EPUBFixture {
    /// Writes `package.opf` plus one `chapterN.xhtml` per entry in `chapters` into a fresh directory
    /// under `directory` and returns that directory. Each entry is placed inside `<html><body>...</body></html>`.
    /// There is no `META-INF/container.xml`; `EPUBParser.parsePackage` finds the OPF by scanning.
    static func makeRoot(in directory: URL, chapters: [String], title: String = "Fixture Title") throws -> URL {
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var manifest = ""
        var spine = ""
        for (offset, body) in chapters.enumerated() {
            let name = "chapter\(offset).xhtml"
            manifest += "<item id=\"c\(offset)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(offset)\"/>"
            let html = "<html><body>\(body)</body></html>"
            try Data(html.utf8).write(to: root.appendingPathComponent(name))
        }
        let opf = "<package><metadata><title>\(title)</title></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
        try Data(opf.utf8).write(to: root.appendingPathComponent("package.opf"))
        return root
    }
}
