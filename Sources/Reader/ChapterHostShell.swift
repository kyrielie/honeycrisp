import Foundation

/// The shell document for the chapter host window (roadmap M3, pass 6): a static XHTML page with one
/// `<iframe>` per mounted chapter, stacked, served as the `__app/shell.html` app resource. It contains
/// no script, because author JavaScript is off for the whole web view. Sizing is done by
/// `ChapterHostScript`, which runs in the client world.
///
/// Served with the handler's `application/xhtml+xml` type for `.html`, so it must stay well-formed XML.
enum ChapterHostShell {
    struct Frame: Equatable {
        /// Spine index, written as `data-resource` and used to order frames.
        let resource: Int
        /// Percent-encoded absolute path under `honeycrisp-epub://book`, for example `/Text/Chapter%202.xhtml`.
        let path: String
    }

    /// Frames are ordered by `resource`. File names are untrusted, so every attribute value is XML-escaped.
    static func html(frames: [Frame]) -> String {
        let iframes = frames.sorted { $0.resource < $1.resource }
            .map { "<iframe class=\"hc-frame\" data-resource=\"\($0.resource)\" src=\"\(escape($0.path))\" scrolling=\"no\"></iframe>" }
            .joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Honeycrisp</title>
            <style>/*<![CDATA[*/
            html, body { margin: 0; padding: 0; background: transparent; }
            iframe.hc-frame { display: block; width: 100%; height: 0; border: 0; overflow: hidden; }
            /*]]>*/</style></head>
            <body>
            \(iframes)
            </body></html>
            """
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
/// definition in contract C2). Any failure is recorded
/// on the frame as `data-hc-error`, never thrown. The source contains no interpolated data; the CSS
/// reaches `applyUserCSS` as an argument and is only ever assigned to `textContent`.
enum ChapterHostScript {
    static let source = #"""
        (function () {
          if (window.honeycrispHost) { return; }
          // TEMPORARY (frame-fit investigation): one entry per fit call, read by ChapterHostFrameFitProbeTests.
          var fitLog = [];
          function fit(frame, trigger) {
            try {
              var doc = frame.contentDocument;
              if (!doc || !doc.documentElement) { return; }
              var root = doc.documentElement;
              var overflow = Math.max(root.scrollHeight, doc.body ? doc.body.scrollHeight : 0);
              var client = frame.clientHeight;
              // scrollHeight never drops below the frame's own height, so a chapter that became shorter
              // would keep the old height. Without overflow the html box is the content height.
              var height = overflow > client ? overflow : root.offsetHeight;
              var apply = height > 0 && frame.getAttribute('data-hc-height') !== String(height);
              if (fitLog.length < 200) {
                fitLog.push({ t: Math.round(performance.now()), trigger: trigger, resource: frame.getAttribute('data-resource'),
                  ready: doc.readyState, sheets: doc.styleSheets.length, client: client, rootScroll: root.scrollHeight,
                  bodyScroll: doc.body ? doc.body.scrollHeight : -1, rootOffset: root.offsetHeight, height: height, applied: apply });
              }
              if (apply) {
                frame.style.height = height + 'px';
                frame.setAttribute('data-hc-height', String(height));
              }
            } catch (error) {
              frame.setAttribute('data-hc-error', String(error));
            }
          }
          function frames() {
            return Array.prototype.slice.call(document.querySelectorAll('iframe.hc-frame'));
          }
          function fitAll(trigger) {
            frames().forEach(function (frame) { fit(frame, typeof trigger === 'string' ? trigger : 'api'); });
          }
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
          // A frame can be measured before its styles have been applied, and nothing would resize it again.
          // Re-measure once the load handlers have run, and again when the whole shell has finished loading.
          frames().forEach(function (frame) {
            frame.addEventListener('load', function () {
              fit(frame, 'load');
              setTimeout(function () { fit(frame, 'load+0'); }, 0);
            });
            fit(frame, 'init');
          });
          window.addEventListener('load', function () { fitAll('window-load'); });
          window.addEventListener('resize', function () { setTimeout(function () { fitAll('resize'); }, 50); });
          window.honeycrispHost = {
            fitLog: fitLog, fitAll: fitAll, applyUserCSS: applyUserCSS,
            offsetOfFirstVisibleText: offsetOfFirstVisibleText, scrollTo: scrollTo
          };
        })();
        """#
}
