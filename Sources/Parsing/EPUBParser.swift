// EPUBParser.swift
// Parses EPUB files into structured content, adapted from the QuickLook plugin

import Foundation
import AppKit
import ZIPFoundation

struct EPUBPackage {
    let rootFolder: URL
    let spineURLs: [URL]
    let title: String
    let author: String
    let coverURL: URL?
}

/// Snapshot of the reader's cosmetic settings (font, size, theme colors,
/// spacing, link clicks) at a single point in time -- everything
/// `EPUBParser.readerVarsCSS` needs. Passed explicitly into
/// buildScrollHTML/buildPageHTML at build time and reused as-is by
/// ReaderViewController.applyCosmeticCSSUpdate for its live JS patch, so both
/// paths are guaranteed to produce identical CSS from identical settings.
struct ReaderCosmeticSettings {
    var fontSizePercent: Int
    var fontFamily: String
    var backgroundCSS: String
    var textCSS: String
    var linkCSS: String
    var lineHeight: Double
    var maxWidth: Int
    var paddingH: Int
    var allowLinkClicks: Bool

    static func current(from s: SettingsManager) -> ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: s.fontSizePercent,
            fontFamily: s.fontFamily,
            backgroundCSS: s.effectiveBackgroundCSS,
            textCSS: s.effectiveTextCSS,
            linkCSS: s.effectiveLinkCSS,
            lineHeight: s.lineHeight,
            maxWidth: s.maxWidth,
            paddingH: s.paddingH,
            allowLinkClicks: s.allowReaderLinkClicks
        )
    }
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

    func buildScrollHTML(from pkg: EPUBPackage, cosmetics: ReaderCosmeticSettings, formatFirstChapter: Bool = false, removeParagraphIndents: Bool = false) throws -> String {
        var body = ""
        let base = pkg.rootFolder
        for i in pkg.spineURLs.indices {
            let extracted = try Self.extractedChapterBody(
                from: pkg, index: i, base: base,
                formatFirstChapter: formatFirstChapter,
                removeParagraphIndents: removeParagraphIndents
            )
            body += "\n<section class=\"ql-chapter\" id=\"chapter-\(i)\" data-chapter-index=\"\(i)\">\n"
                 + extracted
                 + "\n</section>\n"
        }

        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style id="honeycrisp-vars">\(Self.readerVarsCSS(cosmetics))</style>
            <style>\(Self.readerCSS)</style>
        </head>
        <body>
        <div id="content">\(body)</div>
        <script>\(Self.readerJS)</script>
        </body>
        </html>
        """
    }

    /// Paginated-mode counterpart to buildScrollHTML: one spine item's HTML, with
    /// the column layout CSS baked in up front (never injected after load via
    /// evaluateJavaScript — that's what avoids an unstyled flash before
    /// repagination). Uses the same extractedChapterBody helper as buildScrollHTML,
    /// so formatting behaviour can't drift between the two rendering modes.
    func buildPageHTML(
        from pkg: EPUBPackage,
        spineIndex: Int,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        colsPerScreen: ColsPerScreen,
        cosmetics: ReaderCosmeticSettings,
        maxWidth: CGFloat = 700,
        paddingH: CGFloat = 24,
        paddingV: CGFloat = 24,
        formatFirstChapter: Bool = false,
        removeParagraphIndents: Bool = false
    ) throws -> String {
        let base = pkg.rootFolder
        let extracted = try Self.extractedChapterBody(
            from: pkg, index: spineIndex, base: base,
            formatFirstChapter: formatFirstChapter,
            removeParagraphIndents: removeParagraphIndents
        )
        let body = "\n<section class=\"ql-chapter\" id=\"chapter-\(spineIndex)\" data-chapter-index=\"\(spineIndex)\">\n"
            + extracted
            + "\n</section>\n"

        let columnCSS = Self.paginatedColumnCSS(
            viewportWidth: viewportWidth, viewportHeight: viewportHeight, colsPerScreen: colsPerScreen,
            marginH: paddingH, marginV: paddingV, maxWidth: maxWidth
        )

        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style id="honeycrisp-vars">\(Self.readerVarsCSS(cosmetics))</style>
            <style>\(Self.readerCSS)</style>
            <style>\(columnCSS)</style>
        </head>
        <body>
        <div id="content">\(body)</div>
        <script>\(Self.readerJS)</script>
        </body>
        </html>
        """
    }

    /// Horizontal CSS multi-column layout, ported from Ambrosia's
    /// ReaderPreferences.paginatedColumnCSS. Column geometry math and comments kept
    /// as-is — these are empirical WebKit-version-specific fixes, not style
    /// choices. marginH/marginV/maxWidth now come from SettingsManager's
    /// paddingH/paddingV/maxWidth, read by the caller (ReaderViewController.
    /// loadSpineItem) and passed through buildPageHTML — see the appearance-
    /// settings merge pass.
    private static func paginatedColumnCSS(
        viewportWidth: CGFloat, viewportHeight: CGFloat, colsPerScreen: ColsPerScreen,
        marginH: CGFloat, marginV: CGFloat, maxWidth: CGFloat
    ) -> String {
        let cols = colsPerScreen.rawValue

        let vw = Int(viewportWidth.rounded())
        let vh = Int(viewportHeight.rounded())
        let marginHInt = Int(marginH.rounded())

        // colWidth/colGap divide (vw - 2*marginH) — html's content box after its own
        // padding is subtracted — not vw directly. See ReaderPreferences.paginatedColumnCSS
        // in Ambrosia for the full column-fragmentation-vs-container-padding rationale;
        // dividing vw itself here would double-subtract the margin.
        let availableWidth = vw - 2 * marginHInt

        var colGap = max(1, Int((marginH * 2).rounded()))
        let colWidth: Int
        if cols <= 1 {
            colWidth = availableWidth
        } else {
            let raw = availableWidth + colGap
            let overhang = raw % cols
            if overhang != 0 { colGap += cols - overhang }
            colWidth = (availableWidth + colGap) / cols - colGap
        }

        let capSingleColumn = cols <= 1 && maxWidth < CGFloat(availableWidth)
        let bodyWidthCSS = capSingleColumn
            ? "max-width: \(Int(maxWidth))px !important; margin: 0 auto !important;"
            : "max-width: none !important; margin: 0 !important;"

        return """
        /* === Honeycrisp paginated layout === */
        html {
            /* :root is the column container and the scroll container.
               Horizontal margin lives here (container-level padding — applies
               once, at the true first/last column edge only). */
            width: \(vw)px !important;
            height: \(vh)px !important;
            max-width: \(vw)px !important;
            max-height: \(vh)px !important;
            min-width: \(vw)px !important;
            min-height: \(vh)px !important;
            padding-left: \(marginHInt)px !important;
            padding-right: \(marginHInt)px !important;
            padding-top: \(Int(marginV))px !important;
            padding-bottom: \(Int(marginV))px !important;
            column-width: \(colWidth)px !important;
            column-gap: \(colGap)px !important;
            column-fill: auto !important;
            overflow-x: scroll !important;
            overflow-y: hidden !important;
            scrollbar-width: none !important;
            box-sizing: border-box !important;
        }
        html::-webkit-scrollbar { display: none !important; }
        body {
            /* body must NOT be the column container and must NOT carry padding on
               either axis — its own max-width/margin (bodyWidthCSS) only
               crops/centers the rendered text within each already-sized column. */
            width: 100% !important;
            \(bodyWidthCSS)
            height: auto !important;
            overflow: visible !important;
            box-sizing: border-box !important;
        }
        /* Prevent the first element from creating a blank leading column */
        body > *:first-child,
        body > div:first-child > *:first-child {
            break-before: avoid !important;
        }
        /* Long unbreakable inline runs (AO3 tag lists, dl/dd blocks, tables) can
           force a column wider than column-width requests, throwing off every
           column boundary after it (JS assumes a uniform pitch). Force wrapping
           everywhere so no element can be wider than its column. */
        * {
            max-width: 100% !important;
            overflow-wrap: break-word !important;
            word-break: break-word !important;
        }
        """
    }

    /// Extracts and prepares the `<body>` content of a single spine item: strips the
    /// surrounding `<body>` tag, applies AO3 formatting / paragraph-indent stripping /
    /// preface-heading stripping as requested, then rewrites resource URLs to absolute
    /// file URLs. Shared by `buildScrollHTML` (all spine items, merged) and, in a future
    /// paginated-mode HTML builder, a single spine item at a time — kept as one code path
    /// so the two rendering modes can't drift apart on formatting behaviour.
    private static func extractedChapterBody(
        from pkg: EPUBPackage,
        index: Int,
        base: URL,
        formatFirstChapter: Bool,
        removeParagraphIndents: Bool
    ) throws -> String {
        let url = pkg.spineURLs[index]
        let data = try Data(contentsOf: url)
        let src = String(data: data, encoding: .utf8) ?? (String(data: data, encoding: .isoLatin1) ?? "")
        var extracted = Self.extractBody(html: src)

        // Apply AO3 formatting to ALL chapters when enabled
        if formatFirstChapter {
            extracted = Self.applyFirstChapterFormatting(to: extracted)
        }

        if removeParagraphIndents {
            extracted = Self.stripLeadingIndentWhitespace(extracted)
        }

        // AO3 EPUBs emit a redundant "Preface" heading on the first spine item;
        // the spine item is the preface by definition once rendered here.
        if index == 0 {
            extracted = Self.stripPrefaceHeading(extracted)
        }

        return Self.rewriteResourceURLs(in: extracted, base: base)
    }

    /// Strips leading space/tab runs immediately inside paragraph-like elements — the
    /// literal-whitespace equivalent of a `text-indent: 0` CSS override, for books that
    /// fake first-line indentation with actual whitespace characters rather than CSS.
    /// Scoped to `p, div, li` plus headings/blockquote/table cells, since those are
    /// equally plausible homes for a converted-from-plaintext indent. Deliberately does
    /// not touch `&nbsp;`-based fake indents — a different, separate pattern.
    private static func stripLeadingIndentWhitespace(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"(?i)(<(?:p|div|li|h[1-6]|blockquote|td|th)[^>]*>)[ \t]+"#,
            with: "$1", options: .regularExpression)
    }

    /// Strips a redundant "Preface" heading (AO3 uses <h2 class="toc-heading"> in
    /// practice, but the level varies; match h1-h6 with a backreference so only the
    /// matching close tag is eaten). Only ever applied to spine index 0.
    private static func stripPrefaceHeading(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<(h[1-6])[^>]*>\s*[Pp]reface\s*</\1>"#,
            with: "", options: .regularExpression)
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

    // ── Reading position (exact character offset) ─────────────────────────────────
    //
    // Offset contract: UTF-16 code units, counted via a TreeWalker(SHOW_TEXT) over
    // document.body. honeycrispCurrentCharacterOffset (save side) and
    // honeycrispNavigateToOffset (restore side) both walk document.body with the
    // exact same TreeWalker construction, so they can't drift out of sync with
    // each other — one contract, read on one side and written on the other.

    var HONEYCRISP_POSITION_REFERENCE_Y = Math.round(window.innerHeight / 3);

    window.honeycrispCurrentCharacterOffset = function() {
      var x = Math.round(window.innerWidth / 2);
      var y = HONEYCRISP_POSITION_REFERENCE_Y;
      var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      if (!range || !range.startContainer || range.startContainer.nodeType !== Node.TEXT_NODE) {
        return Math.round((window.scrollY / Math.max(1, document.documentElement.scrollHeight)) * 1e6);
      }
      var target = range.startContainer;
      var localOffset = range.startOffset;
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var count = 0, node;
      while ((node = walker.nextNode()) !== null) {
        if (node === target) return count + localOffset;
        count += node.length;
      }
      return count;
    };

    // Seeks scroll mode to a given spine item at a given fraction (0.0-1.0)
    // through that item's rendered height. Used when toggling from paginated
    // mode back to scroll mode, to hand off the live in-session position
    // (spine index + column fraction) rather than falling back to whatever
    // was last persisted to HistoryEntry, which can be stale if the user
    // toggles modes before the debounced position save has flushed.
    window.honeycrispNavigateToChapterFraction = function(spineIndex, fraction) {
      var section = document.getElementById('chapter-' + spineIndex);
      if (!section) return;
      var rect = section.getBoundingClientRect();
      var top = rect.top + window.scrollY;
      var targetY = top + Math.max(0, Math.min(1, fraction)) * rect.height;
      window.scrollTo(0, Math.max(0, targetY));
    };

    window.honeycrispNavigateToOffset = function(targetOffset) {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var count = 0, node, lastNode = null;
      while ((node = walker.nextNode()) !== null) {
        lastNode = node;
        var nextCount = count + node.length;
        if (targetOffset < nextCount) {
          scrollNodeIntoPosition(node, targetOffset - count);
          return;
        }
        count = nextCount;
      }
      // Offset is at or past the end of the document — land on the last text node.
      if (lastNode) scrollNodeIntoPosition(lastNode, lastNode.length);

      function scrollNodeIntoPosition(node, localOffset) {
        localOffset = Math.max(0, Math.min(node.length, localOffset));
        var range = document.createRange();
        range.setStart(node, localOffset);
        range.setEnd(node, localOffset);
        var rect = range.getBoundingClientRect();
        var targetY = window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y;
        window.scrollTo(0, Math.max(0, targetY));
      }
    };

    function reportPosition() {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.positionHandler) {
        window.webkit.messageHandlers.positionHandler.postMessage(window.honeycrispCurrentCharacterOffset());
      }
    }

    // ── Page count (menu bar display) ──────────────────────────────────────────
    //
    // "Page" here means one window-height of scroll, matching paginated mode's
    // one-column-per-page convention. Scroll mode's document is the whole book
    // merged into one continuous document (see buildScrollHTML), so page and
    // totalPages are computed against the document as a whole -- current
    // scroll position over total scrollable height -- not scoped to whichever
    // chapter section the viewport happens to be in. spineIndex/spineCount
    // (via the same .ql-chapter markers navigateToChapter uses) are reported
    // alongside for callers that want chapter position separately.

    window.honeycrispPageInfo = function() {
      var sections = document.querySelectorAll('.ql-chapter');
      var viewTop  = window.scrollY;
      var winH     = Math.max(1, window.innerHeight);
      var docHeight = Math.max(1, document.documentElement.scrollHeight);
      var idx = 0;

      for (var i = 0; i < sections.length; i++) {
        var rect = sections[i].getBoundingClientRect();
        var top  = rect.top + window.scrollY;
        if (top <= viewTop + 1) {
          idx = i;
        }
      }

      var page        = Math.max(1, Math.round(viewTop / winH) + 1);
      var totalPages  = Math.max(1, Math.ceil(docHeight / winH));

      return JSON.stringify({
        page: Math.min(page, totalPages),
        totalPages: totalPages,
        spineIndex: idx,
        spineCount: Math.max(1, sections.length)
      });
    };

    window.reportPageInfo = function() {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pageInfoHandler) {
        window.webkit.messageHandlers.pageInfoHandler.postMessage(window.honeycrispPageInfo());
      }
    };

    // reportPageInfo() is a pure in-memory read (no disk I/O), so it's driven
    // by its own rAF-coalesced call rather than the 500ms debounce below --
    // that debounce exists to throttle reportProgress()/reportPosition()'s
    // disk writes, and folding reportPageInfo() into it left the toolbar page
    // counter stale until 500ms after scrolling stopped.
    var pageInfoRAFPending = false;
    window.addEventListener('scroll', function() {
      if (!pageInfoRAFPending) {
        pageInfoRAFPending = true;
        requestAnimationFrame(function() {
          pageInfoRAFPending = false;
          reportPageInfo();
        });
      }
      clearTimeout(window._progressTimer);
      window._progressTimer = setTimeout(function() {
        reportProgress();
        reportPosition();
      }, 500);
    }, { passive: true });

    // totalPages depends on window.innerHeight, which a scroll event alone
    // doesn't cover -- resizing the window without scrolling left the page
    // counter stale until this listener was added.
    window.addEventListener('resize', function() {
      clearTimeout(window._resizeTimer);
      window._resizeTimer = setTimeout(function() {
        reportPageInfo();
      }, 250);
    }, { passive: true });

    // Page info also needs an immediate read on load (before the first scroll
    // event ever fires), so the menu bar isn't blank until the reader scrolls.
    reportPageInfo();
    """

    // MARK: - CSS

    /// The `:root` CSS custom properties, emitted into their own `<style id="honeycrisp-vars">`
    /// element so `applyCosmeticCSSUpdate` (in ReaderViewController) can replace just this
    /// element's textContent on a settings change, without touching the rest of the stylesheet.
    ///
    /// This is a function of the actual current settings, not a static default —
    /// buildScrollHTML/buildPageHTML bake real values in here at build time (same
    /// treatment paginatedColumnCSS already gets), and applyCosmeticCSSUpdate's
    /// live JS patch calls this exact function too, so there is one definition of
    /// what the vars block contains, not two that can drift apart. Baking real
    /// values in from the start also means there is no longer a static/default
    /// frame to flash before the real ones land -- see ReaderCosmeticSettings.
    static func readerVarsCSS(_ c: ReaderCosmeticSettings) -> String {
        """
        :root {
            color-scheme: light dark;
            --reader-font-size: \(c.fontSizePercent)%;
            --reader-font-family: \(c.fontFamily);
            --reader-bg: \(c.backgroundCSS);
            --reader-text: \(c.textCSS);
            --reader-link: \(c.linkCSS);
            --reader-line-height: \(c.lineHeight);
            --reader-max-width: \(c.maxWidth)px;
            --reader-padding-h: \(c.paddingH)px;
            --reader-link-pointer-events: \(c.allowLinkClicks ? "auto" : "none");
        }
        """
    }

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
        line-height: var(--reader-line-height);
        padding: 0;
        margin: 0;
        background: transparent;
        overflow-x: hidden;
        max-width: 100%;
    }
    
    #content { width: 100%; max-width: var(--reader-max-width); margin: 0 auto; padding: 28px var(--reader-padding-h) 48px; }
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
    
    a { color: var(--reader-link); pointer-events: var(--reader-link-pointer-events); }
    
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
