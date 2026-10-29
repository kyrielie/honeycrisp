// swiftlint:disable file_length
import Foundation

// MARK: - PaginationJS
//
// JS pagination engine for horizontal CSS multi-column paged mode.
// Ported from Ambrosia's PaginationJS.swift (ambrosia* renamed to ql*, matching
// Honeycrisp's existing ql-chapter/ql-hit naming convention), trimmed of
// annotation/highlight-flash code that's specific to Ambrosia's multi-work library
// (Honeycrisp has no highlight/annotation feature).
//
// ARCHITECTURE — CSS pre-loaded, JS reads geometry back:
//   Column layout CSS (see EPUBParser.paginatedColumnCSS) is baked into the HTML
//   string before it is handed to WKWebView.loadHTMLString/loadFileURL, so the
//   browser never renders an un-paginated flash. This file does not compute or
//   receive column geometry from Swift; it reads colWidth/colGap back from
//   getComputedStyle(document.documentElement) after the CSS has already been
//   applied and layout has settled.
//
//   Columns live on :root (`html`), not `body`. `html` is simultaneously the
//   column container and the scroll container, so window.scrollX maps directly
//   to column position.
//
// CHARACTER OFFSET INVARIANT (matches Patch 0005's scroll-mode contract):
//   UTF-16 code units, text nodes only, HTML tags excluded.
//   TreeWalker(NodeFilter.SHOW_TEXT), node.length = UTF-16 code unit count.
//
// EXPOSED GLOBALS (called from Swift via evaluateJavaScript):
//
//   window.qlSetup(colsPerScreen)
//     Read column metrics back from computed style and store them.
//     Call once after loadHTMLString/loadFileURL completes (didFinish navigation).
//
//   window.qlColumnCount()      → Int
//   window.qlCurrentColumn()    → Int
//   window.qlScrollToColumn(n)
//   window.qlScrollToFraction(frac)
//   window.qlProgressFraction() → Double 0–1
//   window.qlNavigateToOffset(charOffset)
//   window.qlOffsetAtCurrentColumn() → Int (offset of the first text on the current page, 0 when none)
//   window.qlPaginationMetrics() → JSON string, read once by Swift after setup
//
// MESSAGES POSTED TO SWIFT (via window.webkit.messageHandlers.*):
//
//   pageAction      { action: 'nextSpineItem' | 'prevSpineItem' }
//   positionUpdate  { fraction: Double, column: Int, totalColumns: Int }
//
// KEYSTROKES: handled entirely in Swift (ReaderViewController / ReaderWebView).
//   JS does not install any keydown listeners.
//
// The script is assembled from several fileprivate chunks below rather than one
// long literal, matching Ambrosia's own split (keeps each chunk readable and
// independently diffable); they are concatenated in order and form a single IIFE.

enum PaginationJS {
    static let script: String = _pjsSetupAndColumnCount + _pjsScrollAndPaging
        + _pjsNavigateToOffset + _pjsMetricsAndHelpers
}

// MARK: - Setup, column count, current column

private let _pjsSetupAndColumnCount: String = #"""
    (function () {
    'use strict';

    // ─── Layout metrics (read from computed style, not from Swift) ────────────

    var _colAndGap     = 0;
    var _colsPerScreen = 1;
    var _ready         = false;

    // ─── Setup ────────────────────────────────────────────────────────────────
    //
    // Called once after didFinish. colsPerScreen is the only value Swift needs
    // to pass — everything else is read from the already-applied CSS.

    window.qlSetup = function (colsPerScreen) {
        _colsPerScreen = colsPerScreen || 1;

        // Read the column width and gap from computed style on :root.
        // These are set by the pre-loaded CSS, so they are already correct.
        var cs = window.getComputedStyle(document.documentElement);
        var colWidth = parseFloat(cs.columnWidth) || window.innerWidth;
        var colGap   = parseFloat(cs.columnGap)   || 0;
        _colAndGap   = colWidth + colGap;

        if (_colAndGap <= 0) {
            // Fallback: divide viewport by colsPerScreen
            _colAndGap = window.innerWidth / _colsPerScreen;
        }

        _ready = true;
        window._colAndGap = _colAndGap;

        // Prevent margin-collapse from creating a blank leading column.
        var first = _firstElementChild(document.body);
        if (first) {
            first.style.setProperty('break-before', 'avoid', 'important');
            if (first.tagName && first.tagName.toLowerCase() === 'div') {
                var inner = _firstElementChild(first);
                if (inner) inner.style.setProperty('break-before', 'avoid', 'important');
            }
        }
    };

    function _firstElementChild(parent) {
        var c = parent ? parent.firstChild : null, limit = 20;
        while (c && limit-- > 0) {
            if (c.nodeType === 1) return c;
            c = c.nextSibling;
        }
        return null;
    }

    // ─── Column count ──────────────────────────────────────────────────────────
    //
    // scrollWidth on :root is authoritative when columns are on :root, with one
    // caveat from moving the horizontal reading margin onto `html` (see
    // EPUBParser.paginatedColumnCSS, "Fix: move the horizontal margin OFF body
    // entirely and onto `html`"): `html` is now BOTH the padding host and the
    // scrolling/column element this function measures. scrollWidth on a
    // scrolling box with overflowing content reliably includes the box's
    // *leading* padding, but WebKit does not count the *trailing* padding once
    // content overflows past it. Subtract the leading padding back out before
    // dividing, or a phantom trailing column strands the reader (next page does
    // nothing because scrollWidth-derived total is one too high).

    window.qlColumnCount = function () {
        if (!_ready || _colAndGap <= 0) return 1;
        var cs       = window.getComputedStyle(document.documentElement);
        var gap      = parseFloat(cs.columnGap)    || 0;
        var padLeft  = parseFloat(cs.paddingLeft)  || 0;
        var swRaw    = document.documentElement.scrollWidth;
        var sw       = swRaw - padLeft;

        return Math.max(1, Math.round((sw + gap) / _colAndGap));
    };

    // ─── Current column ───────────────────────────────────────────────────────
    //
    // Uses round(), not floor(), on scrollX / colAndGap. Rationale: html carries
    // the horizontal reading margin as its own padding and is also the
    // scrolling element. Because scrollWidth undercounts the trailing padding,
    // the browser's native max-scroll clamp (scrollWidth - clientWidth) can
    // land short of the ideal i*colAndGap grid position for the LAST column by
    // an amount that depends on padding/gap. floor() can't absorb that
    // shortfall — it silently rounds down to the second-to-last column, which
    // makes qlNextPage's `next >= total` check never trigger and strands the
    // reader (page-turn does nothing, forever). round() tolerates the shortfall
    // (as long as it's under half a pitch) while still resolving exactly at
    // on-grid positions (0, colAndGap, 2*colAndGap, ...), which is the only
    // place this function is ever called with in normal (non-clamped)
    // navigation.

    window.qlCurrentColumn = function () {
        if (!_ready || _colAndGap <= 0) return 0;
        return Math.max(0, Math.round(window.scrollX / _colAndGap));
    };
    """#

// MARK: - Scroll to column, progress fraction, page navigation

private let _pjsScrollAndPaging: String = #"""

    // ─── Scroll to column n ───────────────────────────────────────────────────

    window.qlScrollToColumn = function (n) {
        if (!_ready) return;
        var max = window.qlColumnCount() - 1;
        var col = Math.max(0, Math.min(Math.round(n), max));
        var target = col * _colAndGap;
        window.scrollTo({ left: target, top: 0, behavior: 'instant' });

        // WebKit undercounts html's trailing padding-right in scrollWidth once
        // content overflows (see qlColumnCount comment above), so the native
        // scroll clamp can land short of `target` — visible only on the
        // terminal column of a spine, where target actually reaches that edge.
        // Measure the real shortfall and compensate visually by shifting
        // rendered content left. This must be done on `body`, NOT
        // `document.documentElement`: html is the element with
        // `background-color: var(--reader-bg)` (see EPUBParser.readerCSS),
        // and a CSS transform moves an element's paint -- background included
        // -- so translating html left uncovers a strip of raw WKWebView/
        // window background on the right edge (shows as a white bar on dark
        // themes). body's own background is transparent, so translating it
        // instead shifts the text without moving the themed background at
        // all, and produces the identical geometric offset since body isn't
        // independently fragmented for this purpose (a transform is a pure
        // repaint offset applied after column layout either way).
        var shortfall = target - window.scrollX;
        document.body.style.transform = shortfall > 0
            ? 'translateX(-' + shortfall + 'px)'
            : '';
    };

    // ─── Progress fraction (0–1) ──────────────────────────────────────────────

    window.qlProgressFraction = function () {
        var total = window.qlColumnCount();
        if (total <= _colsPerScreen) return 1.0;
        var denom = total - _colsPerScreen;
        return Math.min(1.0, window.qlCurrentColumn() / denom);
    };

    window.qlScrollToFraction = function (frac) {
        if (!_ready) return;
        var total = window.qlColumnCount();
        var denom = total - _colsPerScreen;
        var col   = denom > 0 ? Math.round(Math.max(0, Math.min(1, frac)) * denom) : 0;
        window.qlScrollToColumn(col);
    };

    // ─── Page navigation ──────────────────────────────────────────────────────

    window.qlNextPage = function () {
        if (!_ready) return;
        var cur   = window.qlCurrentColumn();
        var total = window.qlColumnCount();
        var next  = cur + _colsPerScreen;
        if (next >= total) {
            _postPageAction('nextSpineItem');
            return;
        }
        window.qlScrollToColumn(next);
        _postPositionUpdate();
    };

    window.qlPrevPage = function () {
        if (!_ready) return;
        var cur = window.qlCurrentColumn();
        if (cur === 0) {
            _postPageAction('prevSpineItem');
            return;
        }
        window.qlScrollToColumn(Math.max(0, cur - _colsPerScreen));
        _postPositionUpdate();
    };
    """#

// MARK: - Navigate to char offset

private let _pjsNavigateToOffset: String = #"""

    // ─── Navigate to char offset ──────────────────────────────────────────────
    //
    // Inserts a zero-size marker at the UTF-16 char offset, reads its X position,
    // and snaps to the containing column. Same offset convention as Patch 0005's
    // scroll-mode functions: UTF-16 code units, text nodes only.

    window.qlNavigateToOffset = function (charOffset) {
        if (!_ready) return;
        var pos = _nodeAtChar(charOffset);
        if (!pos) return;
        // Measure untransformed: the end-of-chapter compensation (see qlScrollToColumn) shifts rect.left by the
        // same amount scrollX falls short, which would skew docX. qlScrollToColumn below sets it again.
        document.body.style.transform = '';
        var pitch = _colAndGap;
        var padLeft = parseFloat(window.getComputedStyle(document.documentElement).paddingLeft) || 0;
        var col = 0;
        // Preferred: the box of the character itself, the same measure as qlOffsetAtCurrentColumn. Column i
        // starts at padLeft + i * pitch, so floor from there. A zero-size marker is not used here: when the
        // character opens a column after a collapsed space, the marker can sit at the end of the previous line.
        // The node is found with a strict `<`, as in qlOffsetAtCurrentColumn: _nodeAtChar uses `<=`, so an offset
        // at the start of a text node resolves to the end of the previous one, which lies in the previous column.
        var probe = document.createRange();
        var found = false;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var rem = charOffset, target = null, local = 0, tn;
        while ((tn = walker.nextNode()) !== null) {
            if (rem < tn.length) { target = tn; local = rem; break; }
            rem -= tn.length;
        }
        var last = target ? Math.min(target.length - 1, local + 64) : -1;
        for (var k = local; k <= last && !found; k++) {
            probe.setStart(target, k);
            probe.setEnd(target, k + 1);
            var rects = probe.getClientRects();
            if (rects.length) {
                col = pitch > 0 ? Math.max(0, Math.floor((rects[0].left + window.scrollX - padLeft + 2) / pitch)) : 0;
                found = true;
            }
        }
        if (!found) {
            // No character with a box nearby (an image-only or collapsed run): fall back to the marker.
            var range = document.createRange();
            range.setStart(pos.node, pos.localOffset);
            range.collapse(true);
            var marker = document.createElement('span');
            marker.style.cssText = 'display:inline;font-size:0;line-height:0;';
            range.insertNode(marker);
            var docX = marker.getBoundingClientRect().left + window.scrollX;
            marker.parentNode.removeChild(marker);
            col = pitch > 0 ? Math.max(0, Math.round(docX / pitch)) : 0;
        }
        window.qlScrollToColumn(col);
        _postPositionUpdate();
    };

    window.qlTurnToRange = function (range) {
        if (!_ready || !range) return 0;
        document.body.style.transform = '';
        var pitch = _colAndGap;
        var padLeft = parseFloat(window.getComputedStyle(document.documentElement).paddingLeft) || 0;
        var rects = range.getClientRects();
        var col = 0;
        if (rects.length > 0 && pitch > 0) {
            col = Math.max(0, Math.floor((rects[0].left + window.scrollX - padLeft + 2) / pitch));
        }
        window.qlScrollToColumn(col);
        _postPositionUpdate();
        return col;
    };

    // ─── Navigate to fragment / element ID ───────────────────────────────────

    window.qlNavigateToFragment = function (id) {
        if (!_ready || !id) return;
        var el = document.getElementById(id);
        if (!el) {
            var named = document.getElementsByName(id);
            el = named.length ? named[0] : null;
        }
        if (!el) {
            try {
                var escaped = (window.CSS && CSS.escape) ? CSS.escape(id) : id.replace(/["\\]/g, '\\$&');
                el = document.querySelector('[id$="-' + escaped + '"]');
            } catch (e) {}
        }
        if (!el) return;
        document.body.style.transform = '';
        var pitch = _colAndGap;
        var padLeft = parseFloat(window.getComputedStyle(document.documentElement).paddingLeft) || 0;
        var rect = el.getBoundingClientRect();
        var docX = rect.left + window.scrollX - padLeft;
        var col = pitch > 0 ? Math.max(0, Math.floor((docX + 2) / pitch)) : 0;
        window.qlScrollToColumn(col);
        _postPositionUpdate();
    };

    // ─── Offset of the first text on the current page ────────────────────────
    //
    // Inverse of qlNavigateToOffset: the UTF-16 offset (same text-node walk, same convention) of the first
    // character laid out in the current column or later. After a reflow (font size, resize, mode switch) the
    // caller seeks to this offset, so the text the reader was on stays on screen. Does not mutate the DOM.
    // A character is on the current page when its left edge is at or past the page's content edge, which is
    // the root's left padding (html carries the horizontal margin, see qlColumnCount); rect.left already
    // includes the scroll position and any end-of-chapter compensation transform (see qlScrollToColumn).
    // Returns the total text length when no text lies on or after the current page, and 0 before setup.

    window.qlOffsetAtCurrentColumn = function () {
        if (!_ready || _colAndGap <= 0) return 0;
        var padLeft = parseFloat(window.getComputedStyle(document.documentElement).paddingLeft) || 0;
        function columnOf(rect) { return Math.floor((rect.left - padLeft + 2) / _colAndGap); }
        // Column of the character at `index`. A character with no box (collapsed whitespace) takes the column of
        // the nearest earlier character that has one, so a space at a column break stays with the page it ends;
        // before any box there is no column (-Infinity). Non-decreasing in document order, so it can be bisected.
        function relColumn(node, index) {
            var r = document.createRange();
            var stop = Math.max(0, index - 64);
            for (var j = index; j >= stop; j--) {
                r.setStart(node, j);
                r.setEnd(node, j + 1);
                var rects = r.getClientRects();
                if (rects.length) return columnOf(rects[0]);
            }
            return -Infinity;
        }
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var whole = document.createRange();
        var consumed = 0, node;
        while ((node = walker.nextNode()) !== null) {
            whole.selectNodeContents(node);
            var boxes = whole.getClientRects();
            if (node.length > 0 && boxes.length && columnOf(boxes[boxes.length - 1]) >= 0) {
                var low = 0, high = node.length - 1;
                while (low < high) {
                    var mid = (low + high) >> 1;
                    if (relColumn(node, mid) >= 0) high = mid; else low = mid + 1;
                }
                return consumed + low;
            }
            consumed += node.length;
        }
        return consumed;
    };
    """#

// MARK: - Metrics, internal helpers, IIFE close

private let _pjsMetricsAndHelpers: String = #"""

    // ─── Metrics (used by Swift to read column count after load) ─────────────

    window.qlPaginationMetrics = function () {
        return JSON.stringify({
            colAndGap: _colAndGap,
            colsPerScreen: _colsPerScreen,
            scrollWidth: document.documentElement.scrollWidth,
            innerWidth: window.innerWidth,
            columns: window.qlColumnCount(),
            column: window.qlCurrentColumn(),
            ready: _ready
        });
    };

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _postPageAction(action) {
        window.webkit.messageHandlers.pageAction.postMessage(
            JSON.stringify({ action: action })
        );
    }

    function _postPositionUpdate() {
        window.webkit.messageHandlers.positionUpdate.postMessage(
            JSON.stringify({
                fraction:     window.qlProgressFraction(),
                column:       window.qlCurrentColumn(),
                totalColumns: window.qlColumnCount()
            })
        );
    }

    function _nodeAtChar(globalOffset) {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var rem = globalOffset, n;
        while ((n = walker.nextNode()) !== null) {
            if (rem <= n.length) return { node: n, localOffset: rem };
            rem -= n.length;
        }
        return n ? { node: n, localOffset: n.length } : null;
    }

    })();
    """#
