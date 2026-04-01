// EPUBParser.swift
// Parses EPUB files into structured content, adapted from the QuickLook plugin

import Foundation
import ZIPFoundation

struct EPUBPackage {
    let rootFolder: URL
    let spineURLs: [URL]
    let title: String
    let author: String
    let coverURL: URL?
}

enum EPUBParseError: Error, LocalizedError {
    case containerNotFound, opfNotFound, malformed, io

    var errorDescription: String? {
        switch self {
        case .containerNotFound: return "Could not find META-INF/container.xml"
        case .opfNotFound:       return "Could not locate the OPF package file"
        case .malformed:         return "EPUB spine is empty or malformed"
        case .io:                return "I/O error while reading EPUB"
        }
    }
}

final class EPUBParser: NSObject {

    func unpackEPUB(at epubURL: URL, to workDir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: epubURL.path, isDirectory: &isDir), isDir.boolValue {
            let dest = workDir.appendingPathComponent("EPUBPackage", isDirectory: true)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.copyItem(at: epubURL, to: dest)
            return dest
        }

        try fm.unzipItem(at: epubURL, to: workDir)
        return workDir
    }

    func parsePackage(at extractedRoot: URL) throws -> EPUBPackage {
        let fm = FileManager.default
        let containerURL = extractedRoot.appendingPathComponent("META-INF/container.xml")

        if fm.fileExists(atPath: containerURL.path) {
            let containerData = try Data(contentsOf: containerURL)
            let container = try XMLDocument(data: containerData)
            if let rootAttr = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first,
               let opfPath = rootAttr.stringValue {
                let opfURL = extractedRoot.appendingPathComponent(opfPath)
                return try parseOPF(at: opfURL)
            }
        }

        if let e = fm.enumerator(at: extractedRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in e {
                if url.pathExtension.lowercased() == "opf" { return try parseOPF(at: url) }
            }
        }

        throw EPUBParseError.opfNotFound
    }

    private func parseOPF(at opfURL: URL) throws -> EPUBPackage {
        let rootFolder = opfURL.deletingLastPathComponent()
        let opfData = try Data(contentsOf: opfURL)
        let opf = try XMLDocument(data: opfData)

        let titleNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']")).first as? XMLElement
        let authorNode = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']")).first as? XMLElement
        let bookTitle = titleNode?.stringValue ?? "Unknown Title"
        let bookAuthor = authorNode?.stringValue ?? ""

        var hrefByID: [String: String] = [:]
        var mediaTypeByID: [String: String] = [:]
        let itemNodes = (try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) as? [XMLElement] ?? []
        for item in itemNodes {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue {
                hrefByID[id] = href
                mediaTypeByID[id] = item.attribute(forName: "media-type")?.stringValue ?? ""
            }
        }

        var coverURL: URL?
        let coverMeta = (try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='meta'][@name='cover']")) as? [XMLElement]
        if let coverID = coverMeta?.first?.attribute(forName: "content")?.stringValue,
            let coverHref = hrefByID[coverID] {
            let decoded = coverHref.removingPercentEncoding ?? coverHref
            let u = URL(fileURLWithPath: decoded, relativeTo: rootFolder).standardizedFileURL
            if FileManager.default.fileExists(atPath: u.path) { coverURL = u }
        }
        if coverURL == nil {
            for (id, href) in hrefByID {
                if href.lowercased().contains("cover"), let mt = mediaTypeByID[id], mt.hasPrefix("image/") {
                    let decoded = href.removingPercentEncoding ?? href
                    let u = URL(fileURLWithPath: decoded, relativeTo: rootFolder).standardizedFileURL
                    if FileManager.default.fileExists(atPath: u.path) { coverURL = u; break }
                }
            }
        }

        var spineHrefs: [String] = []
        let spineNodes = (try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) as? [XMLElement] ?? []
        for node in spineNodes {
            if let ref = node.attribute(forName: "idref")?.stringValue, let href = hrefByID[ref] {
                spineHrefs.append(href)
            }
        }

        let spineURLs: [URL] = spineHrefs.compactMap { href in
            let decoded = href.removingPercentEncoding ?? href
            let u = URL(fileURLWithPath: decoded, relativeTo: rootFolder).standardizedFileURL
            return ["xhtml", "html", "htm"].contains(u.pathExtension.lowercased()) ? u : nil
        }

        guard !spineURLs.isEmpty else { throw EPUBParseError.malformed }
        return EPUBPackage(rootFolder: rootFolder, spineURLs: spineURLs, title: bookTitle, author: bookAuthor, coverURL: coverURL)
    }

    // MARK: - HTML building

    func buildScrollHTML(from pkg: EPUBPackage, formatFirstChapter: Bool = false) throws -> String {
        var body = ""
        let base = pkg.rootFolder
        for (i, url) in pkg.spineURLs.enumerated() {
            let data = try Data(contentsOf: url)
            let src = String(data: data, encoding: .utf8) ?? (String(data: data, encoding: .isoLatin1) ?? "")
            var extracted = Self.extractBody(html: src)

            // Apply AO3 formatting to ALL chapters when enabled
            if formatFirstChapter {
                extracted = Self.applyFirstChapterFormatting(to: extracted)
            }

            body += "\n<section class=\"ql-chapter\" id=\"chapter-\(i)\" data-chapter-index=\"\(i)\">\n"
                 + Self.rewriteResourceURLs(in: extracted, base: base)
                 + "\n</section>\n"
        }

        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>\(Self.readerCSS)</style>
        </head>
        <body>
        <div id="content">\(body)</div>
        <script>\(Self.readerJS)</script>
        </body>
        </html>
        """
    }

    // MARK: - First Chapter Formatting Quirk

    /// Hides `.toc-heading` h2 blocks and upsizes `.calibre2` bold elements to h2-scale.
    private static func applyFirstChapterFormatting(to html: String) -> String {
        // Hide toc-heading h2
        var result = html.replacingOccurrences(
            of: #"<h2[^>]*class="[^"]*toc-heading[^"]*"[^>]*>[\s\S]*?<\/h2>"#,
            with: "",
            options: .regularExpression
        )
        // Upsize calibre2 bold to h2 equivalent via inline style injection
        result = result.replacingOccurrences(
            of: #"(<b[^>]*class="[^"]*calibre2[^"]*"[^>]*)(>)"#,
            with: #"$1 style="font-size:1.5em;font-weight:700;display:block;margin:0.5em 0;"$2"#,
            options: .regularExpression
        )
        return result
    }

    private static func extractBody(html: String) -> String {
        guard let start = html.range(of: "<body", options: .caseInsensitive),
              let gt = html[start.lowerBound...].firstIndex(of: ">"),
              let end = html.range(of: "</body>", options: .caseInsensitive)
        else { return html }
        return String(html[html.index(after: gt)..<end.lowerBound])
    }

    private static func rewriteResourceURLs(in html: String, base: URL) -> String {
        let patterns = ["src=\"([^\"]+)\"", "href=\"([^\"]+)\""]
        var out = html
        for p in patterns {
            out = out.replacingOccurrences(of: p) { match, matched in
                let whole = match.range
                let cap = match.range(at: 1)
                let capInMatch = NSRange(location: cap.location - whole.location, length: cap.length)
                let nsMatched = matched as NSString
                let val = nsMatched.substring(with: capInMatch)

                if val.hasPrefix("http") || val.hasPrefix("file:") || val.hasPrefix("data:") ||
                   val.hasPrefix("#") || val.hasPrefix("mailto:") || val.hasPrefix("javascript:") {
                    return matched
                }

                let local = val.hasPrefix("/") ? String(val.dropFirst()) : val
                let abs = URL(fileURLWithPath: local, relativeTo: base).standardizedFileURL.absoluteString
                return nsMatched.replacingCharacters(in: capInMatch, with: abs)
            }
        }
        return out
    }

    // MARK: - JS injected into reader page (progress reporting + TOC navigation)

    static let readerJS = """
    // ── Search ────────────────────────────────────────────────────────────────────

    var _hits = [];
    var _hitIdx = -1;

    /**
     * Highlight all occurrences of `term` across all chapter sections.
     * Returns the total hit count (read by Swift via evaluateJavaScript).
     */
    window.searchText = function(term) {
      // 1. Remove previous highlights
      document.querySelectorAll('mark.ql-hit').forEach(function(m) {
        var parent = m.parentNode;
        parent.replaceChild(document.createTextNode(m.textContent), m);
        parent.normalize();
      });
      _hits = [];
      _hitIdx = -1;

      if (!term || term.length < 2) return 0;

      // 2. Walk all text nodes and wrap matches
      var escapedTerm = term.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      var re = new RegExp(escapedTerm, 'gi');

      function walkNode(node) {
        if (node.nodeType === Node.TEXT_NODE) {
          var text = node.textContent;
          if (!re.test(text)) return;
          re.lastIndex = 0;

          var frag = document.createDocumentFragment();
          var last = 0;
          var m;
          while ((m = re.exec(text)) !== null) {
            frag.appendChild(document.createTextNode(text.slice(last, m.index)));
            var mark = document.createElement('mark');
            mark.className = 'ql-hit';
            mark.textContent = m[0];
            frag.appendChild(mark);
            _hits.push(mark);
            last = re.lastIndex;
          }
          frag.appendChild(document.createTextNode(text.slice(last)));
          node.parentNode.replaceChild(frag, node);
        } else if (
          node.nodeType === Node.ELEMENT_NODE &&
          node.tagName !== 'SCRIPT' &&
          node.tagName !== 'STYLE' &&
          node.tagName !== 'MARK'
        ) {
          // Clone childNodes list to avoid live-collection mutation issues
          Array.from(node.childNodes).forEach(walkNode);
        }
      }

      walkNode(document.body);

      // 3. Scroll first hit into view and mark it active
      if (_hits.length > 0) {
        _hitIdx = 0;
        _activateHit(_hitIdx);
      }

      return _hits.length;
    };

    /**
     * Advance (+1) or retreat (-1) through search results.
     */
    window.nextSearchResult = function(direction) {
      if (_hits.length === 0) return;
      _hits[_hitIdx].classList.remove('ql-active');
      _hitIdx = (_hitIdx + direction + _hits.length) % _hits.length;
      _activateHit(_hitIdx);
    };

    function _activateHit(idx) {
      var hit = _hits[idx];
      hit.classList.add('ql-active');
      hit.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }

    // ── Chapter navigation ────────────────────────────────────────────────────────

    window.navigateToChapter = function(idx) {
      var sections = document.querySelectorAll('.ql-chapter');
      if (idx >= 0 && idx < sections.length) {
        sections[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    };

    window.navigateToFragment = function(id) {
      var el = document.getElementById(id) || document.querySelector('[name="' + id + '"]');
      if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    };

    // ── Reading progress ──────────────────────────────────────────────────────────

    function reportProgress() {
      var scrolled = window.scrollY + window.innerHeight;
      var total    = document.documentElement.scrollHeight;
      var pct      = total > 0 ? Math.round((scrolled / total) * 100) : 0;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.progressHandler) {
        window.webkit.messageHandlers.progressHandler.postMessage(Math.min(100, pct));
      }
    }

    window.addEventListener('scroll', function() {
      clearTimeout(window._progressTimer);
      window._progressTimer = setTimeout(reportProgress, 500);
    }, { passive: true });
    """

    // MARK: - CSS

    static let readerCSS = """
    /* Search highlight colours */
    mark.ql-hit {
        background: #FFEE58;
        color: inherit;
        border-radius: 2px;
        padding: 0 1px;
    }
    mark.ql-hit.ql-active {
        background: #FF9800;
        outline: 2px solid #E65100;
    }

    :root {
        color-scheme: light dark;
        --reader-font-size: 100%;
        --reader-font-family: ui-sans-serif, -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
        --reader-bg: transparent;
        --reader-text: var(--system-text);
        --system-text: CanvasText;
    }

    @media (prefers-color-scheme: dark) {
        :root { 
            --system-text: #e8e0d4;
        }
    }

    html {
        box-sizing: border-box;
        overflow-x: hidden;
        max-width: 100%;
        background-color: var(--reader-bg) !important;
        font-size: var(--reader-font-size);
    }
    
    *, *::before, *::after { box-sizing: inherit; }
    
    body {
        font-family: var(--reader-font-family) !important;
        color: var(--reader-text) !important;
        font-size: 1.1rem;
        line-height: 1.6;
        padding: 0;
        margin: 0;
        background: transparent;
        overflow-x: hidden;
        max-width: 100%;
    }
    
    #content { width: 100%; max-width: 720px; margin: 0 auto; padding: 28px 32px 48px; }
    .ql-chapter { margin: 40px 0; }
    .ql-chapter + .ql-chapter {
        border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent);
        padding-top: 40px;
    }
    
    img, svg, video, iframe { max-width: 100%; height: auto; display: block; margin: 1.2em auto; }
    
    h1, h2, h3, h4, h5, h6 {
        font-family: var(--reader-font-family) !important;
        line-height: 1.25;
        margin-top: 1.5em;
        margin-bottom: 0.5em;
    }
    
    blockquote {
        border-inline-start: 3px solid color-mix(in srgb, currentColor 20%, transparent);
        padding-inline-start: 12px;
        margin-inline: 0;
        color: color-mix(in srgb, currentColor 80%, black);
    }
    
    code, pre {
        font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace !important;
        white-space: pre-wrap;
        word-break: break-all;
    }
    
    a { color: -apple-system-blue; }
    
    * { 
        font-family: inherit !important; 
        color: inherit !important; 
        background-color: transparent !important; 
    }
    
    img, svg { color: unset !important; }
    """
}

private extension String {
    func replacingOccurrences(of pattern: String, with transform: (_ match: NSTextCheckingResult, _ matched: String) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var result = self
        var delta = 0
        let originalNSString = self as NSString
        for m in re.matches(in: self, range: NSRange(startIndex..., in: self)) {
            let matched = originalNSString.substring(with: m.range)
            let replacement = transform(m, matched)
            let adjustedRange = NSRange(location: m.range.location + delta, length: m.range.length)
            result = (result as NSString).replacingCharacters(in: adjustedRange, with: replacement)
            delta += replacement.count - m.range.length
        }
        return result
    }
}
