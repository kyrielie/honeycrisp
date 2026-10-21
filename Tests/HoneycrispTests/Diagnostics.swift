import Foundation

/// Where tests put measurements and other diagnostics (roadmap M3 onward). A test either passes or fails;
/// numbers a human needs go to a file in the repo, never only to stdout or to an Xcode attachment.
///
/// Files land in `<repo>/build/diagnostics/` (`build/` is gitignored). `test.sh` clears the directory
/// before a run and writes `environment.txt` next to the test output. A failed write throws, so the
/// test fails instead of silently losing its numbers.
enum TestDiagnostics {
    /// Repo root, derived from this file's compile-time path (`Tests/HoneycrispTests/Diagnostics.swift`).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var directory: URL {
        repoRoot.appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Writes `lines` to `<directory>/<name>` (one per line, replacing any earlier file) and returns the URL.
    @discardableResult
    static func write(_ name: String, lines: [String]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        return url
    }
}
