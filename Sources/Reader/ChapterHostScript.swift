import Foundation

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
    /// The complete script: `sourceHead` followed directly by `sourceTail` (split only to keep each file short).
    static let source = sourceHead + sourceTail

    /// First half: sizing, measured heights, offsets, scroll-to and user CSS.
    private static let sourceHead = #"""
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
          // A slot is above the reading position when its bottom edge is at or above the reference line (a third of the way
          // down the window, where the position is read). Until the first position has been established (`emptyHeld`) a
          // slot with no height yet is not counted: on open it is the first mounted chapter sitting at the window top and
          // its growth must push the text below it down, and during a restore the explicit placement follows.
          var emptyHeld = true, restoring = false;
          function isAbove(rect) {
            return rect.bottom <= Math.round(window.innerHeight / 3) && (rect.height > 0 || !emptyHeld);
          }
          // Sets the slot height and keeps the text on screen stationary when the slot lies above the reading position.
          // `before` is the slot's rect taken before anything about it changed.
          function setSlotHeight(slot, height, before) {
            var rect = before || slot.getBoundingClientRect();
            var delta = height - rect.height;
            slot.style.height = height + 'px';
            if (delta !== 0 && isAbove(rect)) { window.scrollBy(0, delta); }
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
              // A frame that was just mounted still shows its initial about:blank document. Its height is not the
              // chapter's: recording it would shrink the slot to a few px and corrupt the running ratio.
              if (doc.location.href === 'about:blank') { return; }
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
                // Without a restore the first measured chapter is the one at the window top: the position is set.
                if (!restoring) { emptyHeld = false; }
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
              if (!doc || !doc.body) { return false; }
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
              var r = range.getBoundingClientRect();
              var rtop = r && r.height > 0 ? r.top : 0;
              if (rtop === 0) {
                // A collapsed range in unrendered whitespace has no box: use the nearest element instead.
                var el = found.nodeType === 1 ? found : found.parentElement;
                if (el && el !== doc.body && el !== doc.documentElement) { rtop = el.getBoundingClientRect().top; }
                else if (found.previousElementSibling) { rtop = found.previousElementSibling.getBoundingClientRect().bottom; }
                else if (found.nextElementSibling) { rtop = found.nextElementSibling.getBoundingClientRect().top; }
              }
              var top = frame.getBoundingClientRect().top + rtop;
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

        """#
}
