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

/// Client-world script for the shell document (a `WKUserScript` in `.defaultClient`, main frame only,
/// at document end). It is the only app script in flag mode and relies on assumption A1: with content
/// JavaScript disabled it still runs, and can read the DOM of same-scheme iframes. It sizes each iframe
/// to its chapter's height on load (again right after, and once more when the shell's own load
/// finishes) and when the window resizes, and exposes `honeycrispHost.fitAll()`
/// and `honeycrispHost.applyUserCSS(css)` (replaces the text of `<style id="honeycrisp-user">`, the id is
/// `ServedChapter.userStyleID`, in every mounted chapter document, then re-fits), `offsetOfFirstVisibleText(x)`
/// and `scrollTo(resource, offset)` (reading position as `{resource, offset}`, offsets counted by the one
/// definition in contract C2). From M4 it also mounts and evicts chapter iframes inside `div.hc-slot` elements as the
/// window scrolls (`reconcile`, `mountedResources`; mount margin 2 viewport heights, evict margin 4, at most 5
/// mounted, a slot that intersects the viewport is never evicted). Any failure is recorded
/// on the frame as `data-hc-error`, never thrown. The source contains no interpolated data; the CSS
/// reaches `applyUserCSS` as an argument and is only ever assigned to `textContent`.
enum ChapterHostScript {
    static let source = #"""
        (function () {
          if (window.honeycrispHost) { return; }
          // Measured heights (M4 pass 3). A chapter's measured height replaces the slot's height. When the slot
          // ends at or above the viewport top, the same JS turn scrolls by the difference, so no frame paints
          // between the height change and the compensation (`overflow-anchor: none` keeps WebKit from also
          // adjusting). `ratio` is the running px per byte of measured chapters, applied to unmeasured slots.
          var measuredBytes = 0, measuredPx = 0, reestimating = false;
          function slotOf(frame) {
            var node = frame.parentNode;
            return node && node.classList && node.classList.contains('hc-slot') ? node : null;
          }
          function ratio() { return measuredBytes > 0 ? measuredPx / measuredBytes : 0; }
          // Sets the slot height and keeps the text on screen stationary when the slot lies above the viewport.
          // `before` is the slot's rect taken before anything about it changed.
          function setSlotHeight(slot, height, before) {
            var rect = before || slot.getBoundingClientRect();
            var delta = height - rect.height;
            slot.style.height = height + 'px';
            if (delta !== 0 && rect.bottom <= 0) { window.scrollBy(0, delta); }
          }
          function reestimate() {
            if (reestimating || ratio() <= 0) { return; }
            reestimating = true;
            slots().forEach(function (slot) {
              if (slot.hasAttribute('data-hc-measured') || frameOf(slot)) { return; }
              var bytes = Number(slot.getAttribute('data-bytes')) || 0;
              if (bytes <= 0) { return; }
              var height = Math.round(Math.max(window.innerHeight, bytes * ratio()));
              if (Math.round(slot.getBoundingClientRect().height) !== height) { setSlotHeight(slot, height); }
            });
            reestimating = false;
          }
          function fit(frame) {
            try {
              var doc = frame.contentDocument;
              if (!doc || !doc.documentElement) { return; }
              var root = doc.documentElement;
              var overflow = Math.max(root.scrollHeight, doc.body ? doc.body.scrollHeight : 0);
              // scrollHeight never drops below the frame's own height, so a chapter that became shorter
              // would keep the old height. Without overflow the html box is the content height.
              var height = overflow > frame.clientHeight ? overflow : root.offsetHeight;
              if (height > 0 && frame.getAttribute('data-hc-height') !== String(height)) {
                var slot = slotOf(frame);
                var before = slot ? slot.getBoundingClientRect() : null;
                frame.style.height = height + 'px';
                frame.setAttribute('data-hc-height', String(height));
                if (slot) {
                  var bytes = Number(slot.getAttribute('data-bytes')) || 0;
                  if (slot.hasAttribute('data-hc-measured')) { measuredPx -= Number(slot.getAttribute('data-hc-measured')); }
                  else { measuredBytes += bytes; }
                  measuredPx += bytes > 0 ? height : 0;
                  slot.setAttribute('data-hc-measured', String(bytes > 0 ? height : 0));
                  setSlotHeight(slot, height, before);
                  reestimate();
                }
              }
            } catch (error) {
              frame.setAttribute('data-hc-error', String(error));
            }
          }
          function frames() {
            return Array.prototype.slice.call(document.querySelectorAll('iframe.hc-frame'));
          }
          function fitAll() { frames().forEach(fit); }
          // Offset contract (C2), same as the merged-document script (`EPUBParser.readerJS`): UTF-16 code
          // units, counted with a TreeWalker(SHOW_TEXT) over the body of ONE chapter document.
          function bodyWalker(doc) { return doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, null); }
          function referenceY() { return Math.round(window.innerHeight / 3); }
          function frameFor(resource) {
            var found = null;
            frames().forEach(function (frame) {
              if (Number(frame.getAttribute('data-resource')) === resource) { found = frame; }
            });
            return found;
          }
          // First text on the reference line (a third of the way down the window): the chapter under that
          // line and the offset of the caret at x (default: the window's center, as the merged script does).
          // null when no chapter is under the line or the line has no text caret.
          function offsetOfFirstVisibleText(x) {
            var y = referenceY();
            if (x === undefined || x === null) { x = Math.round(window.innerWidth / 2); }
            var list = frames();
            for (var i = 0; i < list.length; i++) {
              var rect = list[i].getBoundingClientRect();
              if (y < rect.top || y >= rect.bottom) { continue; }
              try {
                var doc = list[i].contentDocument;
                var range = doc && doc.caretRangeFromPoint ? doc.caretRangeFromPoint(x - rect.left, y - rect.top) : null;
                if (!range || !range.startContainer || range.startContainer.nodeType !== Node.TEXT_NODE) { return null; }
                var walker = bodyWalker(doc), count = 0, node;
                while ((node = walker.nextNode()) !== null) {
                  if (node === range.startContainer) {
                    return { resource: Number(list[i].getAttribute('data-resource')), offset: count + range.startOffset };
                  }
                  count += node.length;
                }
                return null;
              } catch (error) {
                list[i].setAttribute('data-hc-error', String(error));
                return null;
              }
            }
            return null;
          }
          // Scrolls the shell so the text position `offset` of chapter `resource` sits on the reference line.
          // An offset at or past the end lands on the end of the last text node. false when the chapter is
          // not mounted or has no text.
          function scrollTo(resource, offset) {
            var frame = frameFor(resource);
            if (!frame) { return false; }
            try {
              var doc = frame.contentDocument;
              var walker = bodyWalker(doc), count = 0, node, last = null, found = null, local = 0;
              while ((node = walker.nextNode()) !== null) {
                last = node;
                if (offset < count + node.length) { found = node; local = offset - count; break; }
                count += node.length;
              }
              if (!found && last) { found = last; local = last.length; }
              if (!found) { return false; }
              local = Math.max(0, Math.min(found.length, local));
              var range = doc.createRange();
              range.setStart(found, local);
              range.setEnd(found, local);
              var top = frame.getBoundingClientRect().top + range.getBoundingClientRect().top;
              window.scrollTo(0, Math.max(0, window.scrollY + top - referenceY()));
              return true;
            } catch (error) {
              frame.setAttribute('data-hc-error', String(error));
              return false;
            }
          }
          function applyUserCSS(css) {
            var patched = 0;
            frames().forEach(function (frame) {
              try {
                var doc = frame.contentDocument;
                if (!doc || !doc.documentElement) { return; }
                var style = doc.getElementById('honeycrisp-user');
                if (!style) {
                  style = doc.createElementNS('http://www.w3.org/1999/xhtml', 'style');
                  style.setAttribute('id', 'honeycrisp-user');
                  (doc.head || doc.documentElement).appendChild(style);
                }
                style.textContent = css;
                patched += 1;
              } catch (error) {
                frame.setAttribute('data-hc-error', String(error));
              }
            });
            fitAll();
            return patched;
          }
          // Windowing (M4). Slots hold every chapter; only slots near the viewport hold an iframe. An evicted
          // slot keeps its last height, so the document never shrinks when a frame goes away.
          var XHTML = 'http://www.w3.org/1999/xhtml';
          var MOUNT_MARGIN = 2, EVICT_MARGIN = 4, MAX_MOUNTED = 5;
          var reconciling = false, ticking = false, suppressScrolls = 0;
          function slots() { return Array.prototype.slice.call(document.querySelectorAll('div.hc-slot')); }
          function frameOf(slot) { return slot.querySelector('iframe.hc-frame'); }
          // A frame can be measured before its styles have been applied (the first measurement of the second
          // and third frame was about 500 px short, and nothing resized them again). Re-measure once the load
          // handlers have run, and again when the whole shell has finished loading.
          function wire(frame) {
            frame.addEventListener('load', function () {
              fit(frame);
              setTimeout(function () {
                fit(frame);
                frame.setAttribute('data-hc-ready', '1');
                if (pending && Number(frame.getAttribute('data-resource')) === pending.resource) { performRestore(); }
              }, 0);
            });
            fit(frame);
          }
          function mount(slot) {
            if (frameOf(slot)) { return; }
            var frame = document.createElementNS(XHTML, 'iframe');
            frame.setAttribute('class', 'hc-frame');
            frame.setAttribute('data-resource', slot.getAttribute('data-resource'));
            frame.setAttribute('scrolling', 'no');
            frame.setAttribute('src', slot.getAttribute('data-src'));
            slot.appendChild(frame);
            wire(frame);
          }
          function evict(slot) {
            var frame = frameOf(slot);
            if (!frame) { return; }
            slot.style.height = Math.round(slot.getBoundingClientRect().height) + 'px';
            slot.removeChild(frame);
          }
          function mountedResources() {
            return slots().filter(frameOf).map(function (slot) { return Number(slot.getAttribute('data-resource')); })
              .sort(function (a, b) { return a - b; });
          }
          // Distance in px between a slot and the viewport; 0 when they intersect.
          function distance(slot) {
            var rect = slot.getBoundingClientRect();
            if (rect.bottom <= 0) { return -rect.bottom; }
            if (rect.top >= window.innerHeight) { return rect.top - window.innerHeight; }
            return 0;
          }
          // Mounts slots within the mount margin, evicts mounted slots beyond the evict margin (hysteresis) and
          // enforces the cap, nearest first. Slots that intersect the viewport always stay. Re-entrant calls
          // return at once. Returns the number of mounted chapters.
          function reconcile() {
            if (reconciling) { return mountedResources().length; }
            reconciling = true;
            try {
              var vh = window.innerHeight;
              var info = slots().map(function (slot) {
                return { slot: slot, d: distance(slot), mounted: !!frameOf(slot) };
              });
              var inside = info.filter(function (i) { return i.d === 0; });
              var near = info.filter(function (i) {
                return i.d > 0 && i.d <= (i.mounted ? EVICT_MARGIN : MOUNT_MARGIN) * vh;
              }).sort(function (a, b) { return a.d - b.d; });
              var keep = inside.concat(near.slice(0, Math.max(0, MAX_MOUNTED - inside.length)));
              info.forEach(function (i) {
                var wanted = keep.indexOf(i) !== -1;
                if (wanted && !i.mounted) { mount(i.slot); }
                if (!wanted && i.mounted) { evict(i.slot); }
              });
            } catch (error) {
              document.documentElement.setAttribute('data-hc-error', String(error));
            }
            reconciling = false;
            return mountedResources().length;
          }
          function schedule() {
            if (suppressScrolls > 0) { suppressScrolls -= 1; return; }
            if (ticking) { return; }
            ticking = true;
            window.requestAnimationFrame(function () { ticking = false; reconcile(); });
          }
          // Position reporting (M4 pass 4): at most one post per 100 ms of scrolling, to the client-world
          // handler `hostPosition`. The body is a JSON string of numbers only (contract C6).
          var reportTimer = null;
          function reportPosition() {
            reportTimer = null;
            try {
              var pos = offsetOfFirstVisibleText();
              if (!pos) { return; }
              var rect = frameFor(pos.resource).getBoundingClientRect();
              var vh = Math.max(1, window.innerHeight);
              var pages = Math.max(1, Math.ceil(rect.height / vh));
              var page = Math.min(pages, Math.floor(Math.max(0, -rect.top) / vh) + 1);
              window.webkit.messageHandlers.hostPosition.postMessage(JSON.stringify(
                { resource: pos.resource, offset: pos.offset, chapterPage: page, chapterPages: pages }));
            } catch (error) {
              document.documentElement.setAttribute('data-hc-error', String(error));
            }
          }
          function scheduleReport() { if (reportTimer === null) { reportTimer = setTimeout(reportPosition, 100); } }
          function onScroll() { schedule(); scheduleReport(); }
          // Restore (M4 pass 4): bring chapter `resource` into view, mounting it first when needed, wait until
          // its frame has loaded and been re-fitted, then land on `offset` (reference line), on `fraction` of
          // the chapter, or on the chapter start, and reveal the shell.
          var pending = null;
          function slotFor(resource) { return document.querySelector('div.hc-slot[data-resource="' + Number(resource) + '"]'); }
          function reveal() { if (document.body) { document.body.style.visibility = 'visible'; } }
          function loaded(frame) {
            if (frame.getAttribute('data-hc-ready') === '1') { return true; }
            try {
              var doc = frame.contentDocument;
              if (doc && doc.readyState === 'complete' && doc.location.href !== 'about:blank') {
                fit(frame);
                frame.setAttribute('data-hc-ready', '1');
                return true;
              }
            } catch (error) { frame.setAttribute('data-hc-error', String(error)); }
            return false;
          }
          function performRestore() {
            var target = pending;
            pending = null;
            if (!target) { return; }
            var slot = slotFor(target.resource);
            if (slot) {
              var top = slot.getBoundingClientRect().top + window.scrollY;
              if (target.offset !== null) { scrollTo(target.resource, target.offset); }
              else if (target.fraction !== null) {
                var height = slot.getBoundingClientRect().height;
                window.scrollTo(0, Math.max(0, Math.round(top + target.fraction * height - referenceY())));
              } else { window.scrollTo(0, Math.max(0, Math.round(top))); }
            }
            reconcile();
            reveal();
            setTimeout(reportPosition, 0);
          }
          function restoreTo(resource, offset, fraction) {
            var slot = slotFor(resource);
            if (!slot) { reveal(); return false; }
            pending = { resource: Number(resource), offset: offset === undefined ? null : offset, fraction: fraction === undefined ? null : fraction };
            mount(slot);
            window.scrollTo(0, Math.max(0, Math.round(slot.getBoundingClientRect().top + window.scrollY)));
            if (loaded(frameOf(slot))) { performRestore(); }
            return true;
          }
          function numberAttribute(name) {
            var raw = document.body.getAttribute(name);
            return raw === null || isNaN(Number(raw)) ? null : Number(raw);
          }
          frames().forEach(wire);
          if (document.body.hasAttribute('data-hc-restore-resource')) {
            restoreTo(numberAttribute('data-hc-restore-resource'), numberAttribute('data-hc-restore-offset'),
              numberAttribute('data-hc-restore-fraction'));
          } else {
            // The shell opens on its first mounted chapter, as the static window did, not on the empty slots
            // above it. This scroll must not trigger a reconcile: the first window stays as loaded.
            var firstMounted = slots().filter(frameOf)[0];
            if (firstMounted) {
              var firstTop = Math.round(firstMounted.getBoundingClientRect().top + window.scrollY);
              if (firstTop > 0) { suppressScrolls = 1; window.scrollTo(0, firstTop); }
            }
          }
          window.addEventListener('load', fitAll);
          window.addEventListener('scroll', onScroll);
          window.addEventListener('resize', function () { setTimeout(function () { fitAll(); schedule(); }, 50); });
          window.honeycrispHost = {
            fitAll: fitAll, applyUserCSS: applyUserCSS,
            offsetOfFirstVisibleText: offsetOfFirstVisibleText, scrollTo: scrollTo,
            reconcile: reconcile, mountedResources: mountedResources, pixelsPerByte: ratio,
            restoreTo: restoreTo, reveal: reveal
          };
        })();
        """#
}
