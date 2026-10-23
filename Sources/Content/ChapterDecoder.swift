import Foundation

enum ChapterDecoder {
    enum Source: Equatable {
        case bom
        case xmlDeclaration
        case metaCharset
        case utf8
        case windows1252
    }

    struct Decoded: Equatable {
        let text: String
        let source: Source
    }

    static func decode(_ data: Data) -> Decoded {
        if let decoded = decodeBOM(from: data) {
            return decoded
        }
        if let decoded = prescanDeclaration(from: data) {
            return decoded
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, source: .utf8)
        }
        return decodeFallback(from: data)
    }

    private static func decodeBOM(from data: Data) -> Decoded? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) {
                return Decoded(text: text, source: .bom)
            }
        } else if data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                return Decoded(text: text, source: .bom)
            }
        } else if data.starts(with: [0xFF, 0xFE]) {
            let isUTF32LE = data.count >= 4 && data[data.startIndex + 2] == 0x00 && data[data.startIndex + 3] == 0x00
            if !isUTF32LE, let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return Decoded(text: text, source: .bom)
            }
        }
        return nil
    }

    private static func prescanDeclaration(from data: Data) -> Decoded? {
        let scanLength = min(data.count, 1024)
        guard scanLength > 0, let scanString = String(data: data.prefix(scanLength), encoding: .isoLatin1) else {
            return nil
        }
        if let decoded = prescanXMLDeclaration(in: scanString, fullData: data) {
            return decoded
        }
        if let decoded = prescanMetaTag(in: scanString, fullData: data) {
            return decoded
        }
        return nil
    }

    private static func prescanXMLDeclaration(in scanString: String, fullData: Data) -> Decoded? {
        guard let xmlDeclRange = scanString.range(of: "<?xml") else { return nil }
        let rest = scanString[xmlDeclRange.upperBound...]
        guard let endDeclRange = rest.range(of: "?>") else { return nil }
        let declContent = String(rest[..<endDeclRange.lowerBound])
        guard let label = extractAttribute(named: "encoding", in: declContent),
              let encoding = resolveEncoding(from: label),
              !isUTF16(encoding),
              let text = String(data: fullData, encoding: encoding) else {
            return nil
        }
        return Decoded(text: text, source: .xmlDeclaration)
    }

    private static func prescanMetaTag(in scanString: String, fullData: Data) -> Decoded? {
        guard let metaEncoding = findMetaCharset(in: scanString),
              let encoding = resolveEncoding(from: metaEncoding),
              !isUTF16(encoding),
              let text = String(data: fullData, encoding: encoding) else {
            return nil
        }
        return Decoded(text: text, source: .metaCharset)
    }

    private static func decodeFallback(from data: Data) -> Decoded {
        if let text = String(data: data, encoding: .windowsCP1252) {
            return Decoded(text: text, source: .windows1252)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return Decoded(text: text, source: .windows1252)
        }
        return Decoded(text: "", source: .windows1252)
    }

    private static func resolveEncoding(from label: String) -> String.Encoding? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
        guard cfEnc != kCFStringEncodingInvalidId else { return nil }
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }

    private static func isUTF16(_ encoding: String.Encoding) -> Bool {
        encoding == .utf16 || encoding == .utf16LittleEndian || encoding == .utf16BigEndian
    }

    private static func findMetaCharset(in text: String) -> String? {
        var searchRange = text.startIndex..<text.endIndex
        while let metaRange = text.range(of: "<meta", options: .caseInsensitive, range: searchRange) {
            let afterMeta = text[metaRange.upperBound...]
            guard let closeTag = afterMeta.range(of: ">") else { break }
            let metaContent = String(afterMeta[..<closeTag.lowerBound])

            if let charset = extractAttribute(named: "charset", in: metaContent) {
                return charset
            }

            if let httpEquiv = extractAttribute(named: "http-equiv", in: metaContent),
               httpEquiv.caseInsensitiveCompare("content-type") == .orderedSame {
                if let content = extractAttribute(named: "content", in: metaContent),
                   let charset = extractCharsetFromContentType(content) {
                    return charset
                }
            }

            searchRange = closeTag.upperBound..<text.endIndex
        }
        return nil
    }

    private static func extractCharsetFromContentType(_ content: String) -> String? {
        guard let charsetRange = content.range(of: "charset", options: .caseInsensitive) else { return nil }
        var index = charsetRange.upperBound
        index = skipWhitespace(in: content, from: index)
        guard index < content.endIndex && content[index] == "=" else { return nil }
        index = content.index(after: index)
        index = skipWhitespace(in: content, from: index)
        guard index < content.endIndex else { return nil }

        let quoteChar: Character? = (content[index] == "\"" || content[index] == "'") ? content[index] : nil
        if quoteChar != nil {
            index = content.index(after: index)
        }

        let start = index
        while index < content.endIndex {
            let ch = content[index]
            if let closingQuote = quoteChar {
                if ch == closingQuote { break }
            } else if ch == ";" || ch.isWhitespace {
                break
            }
            index = content.index(after: index)
        }
        let result = String(content[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func skipWhitespace(in text: String, from index: String.Index) -> String.Index {
        var curr = index
        while curr < text.endIndex && text[curr].isWhitespace {
            curr = text.index(after: curr)
        }
        return curr
    }

    private static func extractAttribute(named name: String, in tagContent: String) -> String? {
        var searchRange = tagContent.startIndex..<tagContent.endIndex
        while let nameRange = tagContent.range(of: name, options: .caseInsensitive, range: searchRange) {
            let isWordBoundary = (nameRange.lowerBound == tagContent.startIndex) || {
                let prev = tagContent[tagContent.index(before: nameRange.lowerBound)]
                return prev.isWhitespace || prev == "/"
            }()

            if isWordBoundary, let value = parseAttributeValue(after: nameRange.upperBound, in: tagContent) {
                return value
            }
            searchRange = nameRange.upperBound..<tagContent.endIndex
        }
        return nil
    }

    private static func parseAttributeValue(after index: String.Index, in tagContent: String) -> String? {
        var curr = skipWhitespace(in: tagContent, from: index)
        guard curr < tagContent.endIndex && tagContent[curr] == "=" else { return nil }
        curr = tagContent.index(after: curr)
        curr = skipWhitespace(in: tagContent, from: curr)
        guard curr < tagContent.endIndex else { return nil }

        let quoteChar: Character? = (tagContent[curr] == "\"" || tagContent[curr] == "'") ? tagContent[curr] : nil
        if quoteChar != nil {
            curr = tagContent.index(after: curr)
        }

        let valStart = curr
        while curr < tagContent.endIndex {
            let ch = tagContent[curr]
            if let closingQuote = quoteChar {
                if ch == closingQuote { break }
            } else if ch.isWhitespace || ch == "/" || ch == ">" || ch == "?" {
                break
            }
            curr = tagContent.index(after: curr)
        }
        return String(tagContent[valStart..<curr])
    }
}
