import Foundation
import SwiftSoup

struct ChapterText: Equatable {
    let string: String
    let hiddenRanges: [NSRange]
    let blockBreaks: [Int]
    let speechSkipRanges: [NSRange]

    init(
        string: String,
        hiddenRanges: [NSRange],
        blockBreaks: [Int] = [],
        speechSkipRanges: [NSRange] = []
    ) {
        self.string = string
        self.hiddenRanges = hiddenRanges
        self.blockBreaks = blockBreaks
        self.speechSkipRanges = speechSkipRanges
    }

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "dl", "dt", "dd",
        "blockquote", "section", "article", "aside", "header", "footer", "nav", "main", "pre",
        "table", "tr", "td", "th", "figure", "figcaption", "hr", "br", "details", "summary",
        "address", "form", "fieldset",
    ]

    static func extract(fromServedBodyHTML html: String) throws -> ChapterText {
        let fullHTML = "<!doctype html><html><body>\(html)</body></html>"
        let document = try Parser.htmlParser().parseInput(fullHTML, "")
        guard let body = document.body() else {
            return ChapterText(string: "", hiddenRanges: [])
        }

        var textPieces: [String] = []
        var hiddenRanges: [NSRange] = []
        var speechSkipRanges: [NSRange] = []
        var rawBlockBreaks: [Int] = []
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
                if isSpeechSkipped(node, root: body) {
                    let newRange = NSRange(location: currentUTF16Offset, length: length)
                    if let last = speechSkipRanges.last, last.location + last.length == newRange.location {
                        speechSkipRanges[speechSkipRanges.count - 1] = NSRange(location: last.location, length: last.length + newRange.length)
                    } else {
                        speechSkipRanges.append(newRange)
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

            let isBlock: Bool
            if let el = node as? Element {
                isBlock = blockTags.contains(el.tagName().lowercased())
            } else {
                isBlock = false
            }

            if isBlock {
                rawBlockBreaks.append(currentUTF16Offset)
            }

            for child in node.getChildNodes() {
                walk(node: child)
            }

            if isBlock {
                rawBlockBreaks.append(currentUTF16Offset)
            }
        }

        for child in body.getChildNodes() {
            walk(node: child)
        }

        let sortedBreaks = Array(Set(rawBlockBreaks)).sorted()
        return ChapterText(
            string: textPieces.joined(),
            hiddenRanges: hiddenRanges,
            blockBreaks: sortedBreaks,
            speechSkipRanges: speechSkipRanges
        )
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

    private static func isSpeechSkipped(_ node: Node, root: Node) -> Bool {
        var curr: Node? = node
        while let ancestor = curr, ancestor !== root {
            if let element = ancestor as? Element {
                let tag = element.tagName().lowercased()
                if tag == "script" || tag == "style" {
                    return true
                }
                if element.hasAttr("hidden") {
                    return true
                }
                if (try? element.attr("aria-hidden"))?.lowercased() == "true" {
                    return true
                }
            }
            curr = ancestor.parent()
        }
        return false
    }
}
