import Foundation
import SwiftSoup

enum ChapterURLs {
    private static let targetAttributes = ["src", "href", "xlink:href"]

    private struct RewriteContext {
        let baseDir: URL
        let standardizedRoot: URL
        let rootPath: String
        let rootPrefix: String
    }

    static func rewrite(in body: Element, chapterURL: URL, root: URL) throws {
        let baseDir = URL(fileURLWithPath: chapterURL.deletingLastPathComponent().path, isDirectory: true)
        let rootDir = URL(fileURLWithPath: root.path, isDirectory: true)
        let standardizedRoot = rootDir.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = standardizedRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        let context = RewriteContext(
            baseDir: baseDir,
            standardizedRoot: standardizedRoot,
            rootPath: rootPath,
            rootPrefix: rootPrefix
        )

        let allElements = try body.getAllElements()
        for element in allElements {
            for attr in targetAttributes {
                guard element.hasAttr(attr) else { continue }
                try rewriteAttribute(attr, on: element, context: context)
            }
        }
    }

    private static func rewriteAttribute(
        _ attr: String,
        on element: Element,
        context: RewriteContext
    ) throws {
        let rawValue = try element.attr(attr)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#") else { return }

        if let scheme = URLComponents(string: value)?.scheme, !scheme.isEmpty {
            return
        }

        let parts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let targetURL = resolveTargetURL(
            decodedPath: decodedPath,
            baseDir: context.baseDir,
            standardizedRoot: context.standardizedRoot
        )

        let targetPath = targetURL.path
        let isInsideRoot = targetPath == context.rootPath || targetPath.hasPrefix(context.rootPrefix)
        guard isInsideRoot else {
            try element.removeAttr(attr)
            return
        }

        var result = targetURL.absoluteString
        if let fragment = fragment {
            if let encoded = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
                result += "#" + encoded
            } else {
                result += "#" + fragment
            }
        }

        try element.attr(attr, result)
    }

    private static func resolveTargetURL(decodedPath: String, baseDir: URL, standardizedRoot: URL) -> URL {
        if decodedPath.hasPrefix("/") {
            let relative = String(decodedPath.dropFirst())
            return URL(fileURLWithPath: relative, relativeTo: standardizedRoot)
                .absoluteURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
        } else {
            return URL(fileURLWithPath: decodedPath, relativeTo: baseDir)
                .absoluteURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }
}
