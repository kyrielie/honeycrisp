import Foundation
import SwiftSoup

struct ChapterText: Equatable {
    let string: String
    let hiddenRanges: [NSRange]

    static func extract(fromServedBodyHTML html: String) throws -> ChapterText {
        let fullHTML = "<!doctype html><html><body>\(html)</body></html>"
        let document = try Parser.htmlParser().parseInput(fullHTML, "")
        guard let body = document.body() else {
            return ChapterText(string: "", hiddenRanges: [])
        }

        var textPieces: [String] = []
        var hiddenRanges: [NSRange] = []
        var currentUTF16Offset = 0

        func processText(_ rawText: String, node: Node) {
            var text = normalizePreText(rawText, node: node)
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

            if !text.isEmpty {
                textPieces.append(text)
                let length = (text as NSString).length
                if hasHiddenAncestor(node, root: body) {
                    let newRange = NSRange(location: currentUTF16Offset, length: length)
                    if let last = hiddenRanges.last, last.location + last.length == newRange.location {
                        hiddenRanges[hiddenRanges.count - 1] = NSRange(location: last.location, length: last.length + newRange.length)
                    } else {
                        hiddenRanges.append(newRange)
                    }
                }
                currentUTF16Offset += length
            }
        }

        func walk(node: Node) {
            if let textNode = node as? TextNode {
                processText(textNode.getWholeText(), node: node)
                return
            }
            if let dataNode = node as? DataNode {
                processText(dataNode.getWholeData(), node: node)
                return
            }

            for child in node.getChildNodes() {
                walk(node: child)
            }
        }

        for child in body.getChildNodes() {
            walk(node: child)
        }

        return ChapterText(string: textPieces.joined(), hiddenRanges: hiddenRanges)
    }

    private static func normalizePreText(_ rawText: String, node: Node) -> String {
        var text = rawText
        if let parent = node.parent() as? Element {
            let parentTag = parent.tagName().lowercased()
            if (parentTag == "pre" || parentTag == "listing") && node.siblingIndex == 0 {
                if text.hasPrefix("\r\n") {
                    text.removeFirst(2)
                } else if text.hasPrefix("\n") {
                    text.removeFirst(1)
                }
            }
        }
        return text
    }

    private static func hasHiddenAncestor(_ node: Node, root: Node) -> Bool {
        var curr: Node? = node.parent()
        while let ancestor = curr, ancestor !== root {
            if let element = ancestor as? Element, element.hasAttr("hidden") {
                return true
            }
            curr = ancestor.parent()
        }
        return false
    }
}
