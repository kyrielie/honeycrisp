import Foundation

/// The shell document for the chapter host window (roadmap M3, pass 6): a static XHTML page with one
/// `<iframe>` per mounted chapter, stacked, served as the `__app/shell.html` app resource. It contains
/// no script, because author JavaScript is off for the whole web view. Sizing is done by
/// `ChapterHostScript`, which runs in the client world.
///
/// Served with the handler's `application/xhtml+xml` type for `.html`, so it must stay well-formed XML.
enum ChapterHostShell {
    /// First estimate of a chapter's height in px per byte of XHTML (placeholder until measured; roadmap M4, N2).
    static let initialPixelsPerByte = 0.3

    struct Frame: Equatable {
        /// Spine index, written as `data-resource` and used to order frames.
        let resource: Int
        /// Percent-encoded absolute path under `honeycrisp-epub://book`, for example `/Text/Chapter%202.xhtml`.
        let path: String
    }

    /// One spine item in the shell (roadmap M4, slot model): a `div.hc-slot` that holds the chapter's iframe
    /// while it is mounted and is empty, at a fixed height, while it is not.
    struct Slot: Equatable {
        /// Spine index, written as `data-resource`.
        let resource: Int
        /// Percent-encoded absolute path under `honeycrisp-epub://book`; written as `data-src`.
        let path: String
        /// File size of the chapter, written as `data-bytes`. 0 when unknown.
        let byteCount: Int
        /// Height in px of an unmounted slot until the chapter is measured. Mounted slots take the iframe's height.
        let estimatedHeight: Int
        /// True when the slot starts with its iframe in place.
        let mounted: Bool
    }

    /// Where the reader should land once the target chapter has loaded (consumed by the client script from
    /// pass 4 on). Numbers only (contract C6): nothing from a book reaches the shell as text.
    struct Restore: Equatable {
        let resource: Int
        let offset: Int?
        let fraction: Double?
    }

    /// Frames are ordered by `resource`. File names are untrusted, so every attribute value is XML-escaped.
    /// Every frame becomes a mounted slot with no byte count; kept for callers that only need a window.
    static func html(frames: [Frame]) -> String {
        html(
            slots: frames.map { Slot(resource: $0.resource, path: $0.path, byteCount: 0, estimatedHeight: 0, mounted: true) },
            restore: nil)
    }

    /// One slot per spine item, ordered by `resource`. File names are untrusted, so every attribute value is
    /// XML-escaped; numbers are written from `Int` and `Double` values only.
    static func html(slots: [Slot], restore: Restore?) -> String {
        let divs = slots.sorted { $0.resource < $1.resource }.map { slot -> String in
            let path = escape(slot.path)
            let attributes = "class=\"hc-slot\" data-resource=\"\(slot.resource)\" data-src=\"\(path)\" data-bytes=\"\(max(0, slot.byteCount))\""
            if slot.mounted {
                let iframe = "<iframe class=\"hc-frame\" data-resource=\"\(slot.resource)\" src=\"\(path)\" scrolling=\"no\"></iframe>"
                return "<div \(attributes)>\(iframe)</div>"
            }
            return "<div \(attributes) style=\"height: \(max(0, slot.estimatedHeight))px\"></div>"
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Honeycrisp</title>
            <style>/*<![CDATA[*/
            html, body { margin: 0; padding: 0; background: transparent; overflow-anchor: none; }
            .hc-slot { display: block; overflow: hidden; }
            body[data-hc-restore-resource] { visibility: hidden; }
            iframe.hc-frame { display: block; width: 100%; height: 0; border: 0; overflow: hidden; }
            /*]]>*/</style></head>
            <body\(restoreAttributes(restore))>
            \(divs)
            </body></html>
            """
    }

    private static func restoreAttributes(_ restore: Restore?) -> String {
        guard let restore else { return "" }
        var result = " data-hc-restore-resource=\"\(restore.resource)\""
        if let offset = restore.offset { result += " data-hc-restore-offset=\"\(max(0, offset))\"" }
        if let fraction = restore.fraction, fraction.isFinite {
            result += " data-hc-restore-fraction=\"\(min(1, max(0, fraction)))\""
        }
        return result
    }

    static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
