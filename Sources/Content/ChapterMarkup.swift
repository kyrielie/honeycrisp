import Foundation
import SwiftSoup

enum ChapterMarkup {
    enum Syntax: Equatable {
        case xml
        case html
    }

    static func syntax(mediaType: String?, pathExtension: String) -> Syntax {
        if let mediaType = mediaType?.lowercased(), mediaType == "application/xhtml+xml" {
            return .xml
        }
        if mediaType == nil {
            let ext = pathExtension.lowercased()
            if ext == "xhtml" || ext == "xml" {
                return .xml
            }
        }
        return .html
    }

    static func parse(_ source: String, syntax: Syntax) throws -> Document {
        let document: Document
        switch syntax {
        case .xml:
            document = try Parser.xmlParser().parseInput(source, "")
        case .html:
            document = try Parser.htmlParser().parseInput(source, "")
        }
        _ = document.outputSettings().prettyPrint(pretty: false).syntax(syntax: .html).charset(.utf8)
        return document
    }

    static func body(of document: Document) throws -> Element {
        if let body = try document.select("body").first() {
            return body
        }
        if let firstChild = document.children().first() {
            return firstChild
        }
        return document
    }

    static func removeActiveContent(in root: Element) throws {
        let elements = [root] + (try root.select("*").array())
        let urlAttributes: Set<String> = ["href", "src", "xlink:href", "action", "formaction", "poster", "data"]

        for element in elements {
            let tag = element.tagName().lowercased()
            if element !== root {
                if tag == "script" || tag == "iframe" || tag == "object" || tag == "embed" || tag == "base" {
                    try element.remove()
                    continue
                }
                if tag == "meta" && isRefreshMeta(element) {
                    try element.remove()
                    continue
                }
            }

            guard let attributes = element.getAttributes() else { continue }
            for attribute in attributes.asList() {
                let key = attribute.getKey()
                let lowerKey = key.lowercased()

                if lowerKey.hasPrefix("on") || lowerKey == "srcdoc" {
                    try element.removeAttr(key)
                    continue
                }

                if urlAttributes.contains(lowerKey) && isJavaScriptURL(attribute.getValue()) {
                    try element.removeAttr(key)
                }
            }
        }
    }

    static func bodyHTML(of body: Element) throws -> String {
        _ = body.ownerDocument()?.outputSettings().prettyPrint(pretty: false).syntax(syntax: .html).charset(.utf8)
        return try body.html()
    }

    private static func isRefreshMeta(_ element: Element) -> Bool {
        guard let httpEquiv = try? element.attr("http-equiv") else { return false }
        return httpEquiv.caseInsensitiveCompare("refresh") == .orderedSame
    }

    private static func isJavaScriptURL(_ value: String) -> Bool {
        var index = value.startIndex
        while index < value.endIndex {
            let scalar = value[index].unicodeScalars.first!
            if scalar.value <= 32 {
                index = value.index(after: index)
            } else {
                break
            }
        }
        let rest = value[index...]
        return rest.lowercased().hasPrefix("javascript:")
    }
}
