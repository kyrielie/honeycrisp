import Foundation
import SwiftSoup

struct ChapterTransformOptions: Equatable {
    var formatAO3: Bool
    var markSpacers: Bool
    var harvestStyles: Bool

    init(
        formatAO3: Bool = false,
        markSpacers: Bool = false,
        harvestStyles: Bool = true
    ) {
        self.formatAO3 = formatAO3
        self.markSpacers = markSpacers
        self.harvestStyles = harvestStyles
    }
}

enum ChapterTransforms {
    static func apply(
        options: ChapterTransformOptions,
        hidePrefaceHeading: Bool,
        to body: Element
    ) throws {
        if options.formatAO3 {
            try applyAO3Formatting(to: body)
        }
        if options.markSpacers {
            try applySpacerParagraphs(to: body)
        }
        if hidePrefaceHeading {
            try hidePreface(in: body)
        }
    }

    private static func applyAO3Formatting(to body: Element) throws {
        let headings = try body.select("h2")
        for heading in headings {
            guard try heading.classNames().contains("toc-heading") else { continue }
            try heading.attr("hidden", "")
        }

        let bElements = try body.select("b")
        let injection = "font-size:1.5em;font-weight:700;display:block;margin:0.5em 0;"
        for bold in bElements {
            guard try bold.classNames().contains("calibre2") else { continue }
            if bold.hasAttr("style") {
                let existing = try bold.attr("style").trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.isEmpty {
                    try bold.attr("style", injection)
                } else if existing.hasSuffix(";") {
                    try bold.attr("style", existing + injection)
                } else {
                    try bold.attr("style", existing + ";" + injection)
                }
            } else {
                try bold.attr("style", injection)
            }
        }
    }

    private static func applySpacerParagraphs(to body: Element) throws {
        let paragraphs = try body.select("p")
        for paragraph in paragraphs {
            let childNodes = paragraph.getChildNodes()
            guard !childNodes.isEmpty else { continue }
            var isSpacer = true
            for child in childNodes {
                if let textNode = child as? TextNode {
                    if !textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        isSpacer = false
                        break
                    }
                } else if let element = child as? Element, element.tagName().lowercased() == "br" {
                    continue
                } else {
                    isSpacer = false
                    break
                }
            }

            if isSpacer {
                if paragraph.hasAttr("class") {
                    let existing = try paragraph.attr("class").trimmingCharacters(in: .whitespaces)
                    if existing.isEmpty {
                        try paragraph.attr("class", "ql-spacer")
                    } else if try !paragraph.classNames().contains("ql-spacer") {
                        try paragraph.attr("class", "ql-spacer \(existing)")
                    }
                } else {
                    try paragraph.attr("class", "ql-spacer")
                }
            }
        }
    }

    private static func hidePreface(in body: Element) throws {
        let headings = try body.select("h1, h2, h3, h4, h5, h6")
        for heading in headings {
            guard heading.children().isEmpty else { continue }
            let text = heading.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined()
            if text.range(of: #"^\s*[Pp]reface\s*$"#, options: .regularExpression) != nil {
                try heading.attr("hidden", "")
            }
        }
    }
}
