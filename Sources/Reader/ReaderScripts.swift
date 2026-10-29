// ReaderScripts.swift
// Client-world scripts for search, position, navigation, and speech (FRAMEWORK L3 Reader)

// swiftlint:disable file_length
import Foundation

// swiftlint:disable:next type_body_length
enum ReaderScripts {
    static let readerJS = """
    // ── Search ────────────────────────────────────────────────────────────────────

    var _hits = [];
    var _hitIdx = -1;
    var _nativeSearchTerm = null;

    /**
     * Highlight all occurrences of `term` across all chapter sections.
     * Returns the total hit count (read by Swift via evaluateJavaScript).
     */
    window.searchText = function(term) {
      var clearNativeSelection = _nativeSearchTerm !== null;
      // 1. Remove previous highlights
      document.querySelectorAll('mark.ql-hit').forEach(function(m) {
        var parent = m.parentNode;
        parent.replaceChild(document.createTextNode(m.textContent), m);
        parent.normalize();
      });
      _hits = [];
      _hitIdx = -1;
      _nativeSearchTerm = null;

      if (!term || term.length < 1) {
        if (clearNativeSelection) window.getSelection().removeAllRanges();
        return 0;
      }

      if (window._qlPaginated) {
        _nativeSearchTerm = term;
        var escaped = term.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
        var matcher = new RegExp(escaped, 'gi');
        var count = 0;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        var textNode;
        while ((textNode = walker.nextNode()) !== null) {
          var matches = textNode.textContent.match(matcher);
          if (matches) count += matches.length;
        }
        window.getSelection().removeAllRanges();
        window.find(term, false, false, true, false, false, false);
        return count;
      }

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
      if (_nativeSearchTerm) {
        window.find(_nativeSearchTerm, false, direction < 0, true, false, false, false);
        return;
      }
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
      var sections = document.querySelectorAll('.hc-chapter, .ql-chapter');
      if (window._qlPaginated) {
        if (idx >= 0 && idx < sections.length) sections[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
      } else if (idx >= 0 && idx < sections.length) {
        sections[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    };

    window.navigateToFragment = function(id) {
      if (!id) return;
      var el = document.getElementById(id);
      if (!el) {
        var named = document.getElementsByName(id);
        el = named.length ? named[0] : null;
      }
      if (!el) {
        try {
          var escaped = (window.CSS && CSS.escape) ? CSS.escape(id) : id.replace(/["\\\\]/g, '\\\\$&');
          el = document.querySelector('[id$="-' + escaped + '"]');
        } catch (e) {}
      }
      if (!el) {
        el = document.getElementById('hc-r' + id);
      }
      if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    };

    window.navigateToChapterEnd = function(idx) {
      var section = document.getElementById('hc-r' + idx) || document.getElementById('chapter-' + idx);
      if (section) section.scrollIntoView({ behavior: 'smooth', block: 'end' });
    };

    function hcSpeechRoot(resource) {
      return document.getElementById('hc-r' + resource) || document.querySelector('section.hc-chapter') || document.body;
    }

    function hcSpeechBase(root) {
      if (!root || !root.classList || !root.classList.contains('hc-chapter')) return 0;
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var first = walker.nextNode();
      return (first && first.data && first.data.indexOf('\\n') === 0) ? 1 : 0;
    }

    function hcLocate(root, offset, atEnd) {
      var base = hcSpeechBase(root);
      var target = offset + base;
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var count = 0, node, lastNode = null;
      while ((node = walker.nextNode()) !== null) {
        lastNode = node;
        var len = node.length;
        if (atEnd) {
          if (count + len >= target) {
            return { node: node, local: Math.max(0, Math.min(len, target - count)) };
          }
        } else {
          if (count + len > target || (count + len === target && target === 0)) {
            return { node: node, local: Math.max(0, Math.min(len, target - count)) };
          }
        }
        count += len;
      }
      if (lastNode) {
        return { node: lastNode, local: lastNode.length };
      }
      return null;
    }

    function hcGetMergedRects(range) {
      var raw = Array.from(range.getClientRects());
      if (raw.length === 0) return [];
      raw.sort(function(a, b) {
        if (Math.abs(a.top - b.top) > 4) return a.top - b.top;
        return a.left - b.left;
      });
      var merged = [];
      for (var i = 0; i < raw.length; i++) {
        var r = raw[i];
        if (r.width <= 0 || r.height <= 0) continue;
        if (merged.length > 0) {
          var prev = merged[merged.length - 1];
          var vOverlap = Math.min(prev.bottom, r.bottom) - Math.max(prev.top, r.top);
          var minH = Math.min(prev.height, r.height);
          if (vOverlap > minH * 0.5 && r.left - prev.right < 4 && r.left >= prev.left) {
            merged[merged.length - 1] = {
              left: prev.left,
              top: Math.min(prev.top, r.top),
              right: Math.max(prev.right, r.right),
              bottom: Math.max(prev.bottom, r.bottom),
              width: Math.max(prev.right, r.right) - prev.left,
              height: Math.max(prev.bottom, r.bottom) - Math.min(prev.top, r.top)
            };
            continue;
          }
        }
        merged.push({
          left: r.left,
          top: r.top,
          right: r.right,
          bottom: r.bottom,
          width: r.width,
          height: r.height
        });
      }
      return merged;
    }

    window.honeycrispSpeechHighlight = function(resource, sStart, sEnd, wStart, wEnd, follow) {
      var root = hcSpeechRoot(resource);
      if (!root) return { ok: false };
      var sLocStart = hcLocate(root, sStart, false);
      var sLocEnd = hcLocate(root, sEnd, true);
      if (!sLocStart || !sLocEnd) return { ok: false };

      var sRange = document.createRange();
      try {
        sRange.setStart(sLocStart.node, sLocStart.local);
        sRange.setEnd(sLocEnd.node, sLocEnd.local);
      } catch (e) {
        return { ok: false };
      }

      var sRects = hcGetMergedRects(sRange);
      if (sRects.length === 0) {
        window.honeycrispSpeechClear();
        return { ok: false };
      }

      var wRange = null;
      var wRects = [];
      if (typeof wStart === 'number' && wStart >= 0 && typeof wEnd === 'number' && wEnd > wStart) {
        var wLocStart = hcLocate(root, wStart, false);
        var wLocEnd = hcLocate(root, wEnd, true);
        if (wLocStart && wLocEnd) {
          wRange = document.createRange();
          try {
            wRange.setStart(wLocStart.node, wLocStart.local);
            wRange.setEnd(wLocEnd.node, wLocEnd.local);
            wRects = hcGetMergedRects(wRange);
          } catch (e) {
            wRange = null;
            wRects = [];
          }
        }
      }

      var container = document.getElementById('hc-speech-hl');
      if (!container) {
        container = document.createElement('div');
        container.id = 'hc-speech-hl';
        document.documentElement.appendChild(container);
      }
      container.innerHTML = '';

      var scrollX = window.scrollX || 0;
      var scrollY = window.scrollY || 0;

      for (var i = 0; i < sRects.length; i++) {
        var sr = sRects[i];
        var sBox = document.createElement('div');
        sBox.className = 'hc-sp-s';
        sBox.style.left = Math.round(sr.left + scrollX) + 'px';
        sBox.style.top = Math.round(sr.top + scrollY) + 'px';
        sBox.style.width = Math.round(sr.width) + 'px';
        sBox.style.height = Math.round(sr.height) + 'px';
        container.appendChild(sBox);
      }

      for (var j = 0; j < wRects.length; j++) {
        var wr = wRects[j];
        var wBox = document.createElement('div');
        wBox.className = 'hc-sp-w';
        wBox.style.left = Math.round(wr.left + scrollX) + 'px';
        wBox.style.top = Math.round(wr.top + scrollY) + 'px';
        wBox.style.width = Math.round(wr.width) + 'px';
        wBox.style.height = Math.round(wr.height) + 'px';
        container.appendChild(wBox);
      }

      var firstRect = sRects[0];

      // Follow-along logic
      if (follow === 1 && (Date.now() - (window._hcUserScrollAt || 0) > 4000)) {
        if (window._qlPaginated) {
          if (firstRect.left < 0 || firstRect.left >= window.innerWidth) {
            if (window.qlTurnToRange) {
              window.qlTurnToRange(sRange);
            }
          }
        } else {
          var isTall = sRects.length > 1 && (sRects[sRects.length - 1].bottom - firstRect.top > window.innerHeight * 0.5);
          var anchor = (isTall && wRects.length > 0) ? wRects[0] : firstRect;
          if (anchor.top < window.innerHeight * 0.10 || anchor.top > window.innerHeight * 0.70 || anchor.bottom > window.innerHeight * 0.88) {
            var targetY = window.scrollY + anchor.top - HONEYCRISP_POSITION_REFERENCE_Y;
            var dist = Math.abs(window.scrollY - targetY);
            window.scrollTo({
              top: Math.max(0, targetY),
              behavior: dist < window.innerHeight ? 'smooth' : 'auto'
            });
          }
        }
      }

      window._hcSpeech = {
        resource: resource,
        sStart: sStart,
        sEnd: sEnd,
        wStart: wStart,
        wEnd: wEnd,
        follow: follow
      };

      return {
        ok: true,
        sentenceText: sRange.toString(),
        wordText: wRange ? wRange.toString() : '',
        top: firstRect.top,
        bottom: firstRect.bottom,
        left: firstRect.left,
        right: firstRect.right
      };
    };

    window.honeycrispSpeechClear = function() {
      var container = document.getElementById('hc-speech-hl');
      if (container) container.innerHTML = '';
      window._hcSpeech = null;
    };

    window.honeycrispSpeechOffsetOnScreen = function(resource, offset) {
      var root = hcSpeechRoot(resource);
      if (!root) return false;
      var loc = hcLocate(root, offset, false);
      if (!loc) return false;
      var range = document.createRange();
      try {
        range.setStart(loc.node, loc.local);
        range.setEnd(loc.node, Math.min(loc.node.length, loc.local + 1));
        var rects = range.getClientRects();
        if (rects.length === 0) return false;
        var r = rects[0];
        return r.top >= 0 && r.bottom <= window.innerHeight;
      } catch (e) {
        return false;
      }
    };

    window.honeycrispSpeechStartOffset = function(resource, mode, x, y) {
      var root = hcSpeechRoot(resource);
      var base = hcSpeechBase(root);

      function swiftOffset(targetNode, localOffset) {
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
        var count = 0, node;
        while ((node = walker.nextNode()) !== null) {
          if (node === targetNode) {
            return Math.max(0, count + localOffset - base);
          }
          count += node.length;
        }
        return 0;
      }

      var selection = window.getSelection();
      var hasSel = selection && !selection.isCollapsed && selection.rangeCount > 0;
      if (mode === 'auto') {
        if (hasSel && root.contains(selection.anchorNode)) {
          mode = 'selection';
        } else {
          mode = 'viewport';
        }
      }

      if (mode === 'selection' && hasSel) {
        var sRange = selection.getRangeAt(0);
        var sNode = sRange.startContainer;
        var sOffset = sRange.startOffset;
        var elem = sNode.nodeType === Node.ELEMENT_NODE ? sNode : sNode.parentElement;
        var selSec = elem ? elem.closest('.hc-chapter') : null;
        var selRes = resource;
        if (selSec && selSec.hasAttribute('data-resource')) {
          selRes = parseInt(selSec.getAttribute('data-resource'), 10);
        }
        return JSON.stringify({
          resource: selRes,
          offset: swiftOffset(sNode, sOffset),
          source: 'selection'
        });
      }

      if (mode === 'point' && typeof x === 'number' && typeof y === 'number') {
        var pRange = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
        if (pRange && root.contains(pRange.startContainer)) {
          return JSON.stringify({
            resource: resource,
            offset: swiftOffset(pRange.startContainer, pRange.startOffset),
            source: 'point'
          });
        }
      }

      // 'viewport' mode
      var scanY = Math.round(window.innerHeight * 0.08);
      var scanXCandidates = [
        Math.round(window.innerWidth * 0.5),
        Math.round(window.innerWidth * 0.25),
        Math.round(window.innerWidth * 0.75)
      ];

      for (var s = 0; s < scanXCandidates.length; s++) {
        var vRange = document.caretRangeFromPoint ? document.caretRangeFromPoint(scanXCandidates[s], scanY) : null;
        if (vRange && root.contains(vRange.startContainer)) {
          return JSON.stringify({
            resource: resource,
            offset: swiftOffset(vRange.startContainer, vRange.startOffset),
            source: 'viewport'
          });
        }
      }

      return JSON.stringify({
        resource: resource,
        offset: 0,
        source: 'start'
      });
    };

    window.honeycrispCurrentSpeechText = function(spineIndex) {
      var section = document.getElementById('hc-r' + spineIndex) || document.getElementById('chapter-' + spineIndex);
      if (!section) return '';
      var selection = window.getSelection();
      if (selection && !selection.isCollapsed && selection.toString().trim()) return selection.toString();
      var x = Math.round(window.innerWidth / 2), y = Math.round(window.innerHeight / 3);
      var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      var target = range && section.contains(range.startContainer) ? range.startContainer : null;
      var offset = target ? range.startOffset : 0, started = !target, parts = [];
      var walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT, null), node;
      while ((node = walker.nextNode()) !== null) {
        var match = (node === target);
        if (!started && match) started = true;
        var parent = node.parentElement;
        if (parent && parent.closest('script, style, [hidden], [aria-hidden="true"]')) continue;
        if (started) parts.push(node.textContent.slice(match ? offset : 0));
      }
      return parts.join(' ').replace(/\\s+/g, ' ').trim();
    };

    ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(function(type) {
      window.addEventListener(type, function() {
        window._hcUserScrollAt = Date.now();
        if (window.honeycrispAutoScrollFrame) {
          cancelAnimationFrame(window.honeycrispAutoScrollFrame);
          window.honeycrispAutoScrollFrame = null;
        }
      }, { passive: true });
    });

    // ── Reading progress ──────────────────────────────────────────────────────────

    function reportProgress() {
      // Paginated mode clips document height to the viewport and scrolls
      // horizontally (see paginatedColumnCSS: html { height: <vh>px;
      // overflow-y: hidden }), so scrollY stays ~0 and scrollHeight stays
      // ~innerHeight regardless of position -- this math would report ~100%
      // on every single page turn. Paginated progress is instead computed
      // Swift-side from spine index/column (see ReaderViewController.
      // reportPaginatedProgress) and window._qlPaginated (set by
      // buildPageHTML, absent/false in buildScrollHTML) is what tells this
      // shared function to defer to that instead of posting its own bogus
      // value over the same progressHandler channel.
      if (window._qlPaginated) return;
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
    // each other -- one contract, read on one side and written on the other.

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

    window.honeycrispCurrentChapterCharacterOffset = function(optSpineIndex) {
      var section = null;
      if (typeof optSpineIndex === 'number' && optSpineIndex >= 0) {
        section = document.getElementById('hc-r' + optSpineIndex) || document.querySelectorAll('.hc-chapter, .ql-chapter')[optSpineIndex];
      }
      if (!section) {
        var pos = window.honeycrispCurrentPosition();
        return pos ? pos.offset : 0;
      }
      var x = Math.round(window.innerWidth / 2);
      var y = HONEYCRISP_POSITION_REFERENCE_Y;
      var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      var target = range && range.startContainer && section.contains(range.startContainer) ? range.startContainer : null;
      var localOffset = target ? range.startOffset : 0;
      var walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT, null);
      var count = 0, node;
      while ((node = walker.nextNode()) !== null) {
        if (node === target) return count + localOffset;
        count += node.length;
      }
      return count;
    };

    window.honeycrispCurrentPosition = function() {
      var sections = document.querySelectorAll('.hc-chapter, .ql-chapter');
      var x = Math.round(window.innerWidth / 2), y = HONEYCRISP_POSITION_REFERENCE_Y;
      var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      var target = (range && range.startContainer && range.startContainer.nodeType === Node.TEXT_NODE) ? range.startContainer : null;
      var localOffset = target ? range.startOffset : 0;

      if (sections.length > 0) {
        var activeSection = null;
        var resource = 0;
        if (target) {
          for (var s = 0; s < sections.length; s++) {
            if (sections[s].contains(target)) {
              activeSection = sections[s];
              resource = s;
              break;
            }
          }
        }
        if (!activeSection) {
          var viewTop = window.scrollY;
          for (var i = 0; i < sections.length; i++) {
            var rect = sections[i].getBoundingClientRect();
            var top = rect.top + window.scrollY;
            if (top <= viewTop + y + 1) {
              activeSection = sections[i];
              resource = i;
            }
          }
        }
        if (!activeSection) {
          activeSection = sections[0];
          resource = 0;
        }
        var attrRes = activeSection.getAttribute('data-resource');
        if (attrRes !== null && attrRes !== '') {
          resource = parseInt(attrRes, 10);
        }

        var walker = document.createTreeWalker(activeSection, NodeFilter.SHOW_TEXT, null);
        var count = 0, node, matchedOffset = null;
        while ((node = walker.nextNode()) !== null) {
          if (node === target) {
            matchedOffset = count + localOffset;
          }
          count += node.length;
        }
        var offset = matchedOffset !== null ? matchedOffset : 0;
        var fraction = count > 0 ? Math.max(0, Math.min(1, offset / count)) : 0;
        return { resource: resource, offset: offset, fraction: fraction };
      }

      var offset = window.honeycrispCurrentCharacterOffset();
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var length = 0, node;
      while ((node = walker.nextNode()) !== null) length += node.length;
      var hasTextCaret = target !== null;
      var fraction;
      if (hasTextCaret && length > 0) {
        fraction = offset / length;
      } else if (window._qlPaginated && window.qlProgressFraction) {
        fraction = window.qlProgressFraction();
      } else {
        var maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        fraction = maxY > 0 ? window.scrollY / maxY : 0;
      }
      return { resource: 0, offset: offset, fraction: Math.max(0, Math.min(1, fraction)) };
    };

    // Character range currently on screen, as [start, end] in the same offset space
    // as honeycrispCurrentCharacterOffset (paginated: whole body) or
    // honeycrispCurrentChapterCharacterOffset (scroll: the given chapter section).
    // A bookmark whose offset falls inside this range belongs to the visible page,
    // wherever on the page it was dropped. Returns null when nothing is measurable.
    window.honeycrispVisibleCharacterRange = function(scrollMode, spineIndex) {
      var root = document.body;
      if (scrollMode) {
        root = document.getElementById('hc-r' + spineIndex) || document.getElementById('chapter-' + spineIndex);
        if (!root) return null;
      }
      var viewW = window.innerWidth, viewH = window.innerHeight;
      // -1: before the viewport, 1: after it, 0: touches it, null: unmeasurable.
      function side(rect) {
        if (!rect || (rect.width === 0 && rect.height === 0)) return null;
        if (scrollMode) return rect.bottom <= 0 ? -1 : (rect.top >= viewH ? 1 : 0);
        return rect.right <= 0 ? -1 : (rect.left >= viewW ? 1 : 0);
      }
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var nodes = [], starts = [], count = 0, node;
      while ((node = walker.nextNode()) !== null) {
        if (node.data.trim().length > 0) { nodes.push(node); starts.push(count); }
        count += node.length;
      }
      if (!nodes.length) return null;
      var range = document.createRange();
      // First index in [0, n) where pred is true. pred is false then true across
      // the range (reading order is monotonic on screen); null means unmeasurable
      // and is skipped forward.
      function lowerBound(n, pred) {
        var lo = 0, hi = n;
        while (lo < hi) {
          var mid = (lo + hi) >> 1, j = mid, p = pred(j);
          while (p === null && j + 1 < hi) { j += 1; p = pred(j); }
          if (p === null) { hi = mid; continue; }
          if (p) hi = j; else lo = j + 1;
        }
        return lo;
      }
      function nodeSide(i) {
        range.selectNodeContents(nodes[i]);
        return side(range.getBoundingClientRect());
      }
      function charSide(n, k) {
        range.setStart(n, k);
        range.setEnd(n, k);
        return side(range.getBoundingClientRect());
      }
      var firstNode = lowerBound(nodes.length, function(i) {
        var s = nodeSide(i); return s === null ? null : s >= 0;
      });
      var afterNode = lowerBound(nodes.length, function(i) {
        var s = nodeSide(i); return s === null ? null : s > 0;
      });
      if (firstNode >= afterNode) return null;
      var lastNode = afterNode - 1;
      // A long paragraph is one text node and can span several pages, so refine
      // the two edge nodes down to the character that actually starts/ends the page.
      var first = nodes[firstNode], last = nodes[lastNode];
      var startK = lowerBound(first.length + 1, function(k) {
        var s = charSide(first, k); return s === null ? null : s >= 0;
      });
      var endK = lowerBound(last.length + 1, function(k) {
        var s = charSide(last, k); return s === null ? null : s > 0;
      });
      var start = starts[firstNode] + Math.min(startK, first.length);
      var end = starts[lastNode] + Math.min(endK, last.length);
      return [start, Math.max(start, end)];
    };

    window.honeycrispSnippetAtOffset = function(spineIndex, offset, maxLen) {
      maxLen = maxLen || 120;
      var root = document.body;
      if (typeof spineIndex === 'number' && spineIndex >= 0) {
        var sec = document.getElementById('hc-r' + spineIndex) || document.getElementById('chapter-' + spineIndex);
        if (sec) root = sec;
      }
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var count = 0, node, textAcc = '';
      while ((node = walker.nextNode()) !== null) {
        var len = node.length;
        if (count + len > offset) {
          var startInside = Math.max(0, offset - count);
          textAcc += node.data.substring(startInside);
          if (textAcc.length >= maxLen * 2) break;
        }
        count += len;
      }
      var normalized = textAcc.replace(/\\s+/g, ' ').trim();
      if (normalized.length > maxLen) {
        return normalized.substring(0, maxLen).trim() + '…';
      }
      return normalized;
    };

    window.honeycrispNavigateToChapterOffset = function(spineIndex, targetOffset) {
      var section = document.getElementById('hc-r' + spineIndex) || document.getElementById('chapter-' + spineIndex);
      if (!section) return;
      var walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT, null);
      var count = 0, node, lastNode = null;
      while ((node = walker.nextNode()) !== null) {
        lastNode = node;
        if (targetOffset <= count + node.length) {
          var range = document.createRange();
          range.setStart(node, Math.max(0, Math.min(node.length, targetOffset - count)));
          range.setEnd(range.startContainer, range.startOffset);
          var rect = range.getBoundingClientRect();
          window.scrollTo(0, Math.max(0, window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y));
          return;
        }
        count += node.length;
      }
      if (lastNode) {
        var end = document.createRange();
        end.selectNodeContents(lastNode);
        end.collapse(false);
        var rect = end.getBoundingClientRect();
        window.scrollTo(0, Math.max(0, window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y));
      }
    };

    // Seeks scroll mode to a given spine item at a given fraction (0.0-1.0)
    // through that item's rendered height. Used when toggling from paginated
    // mode back to scroll mode, to hand off the live in-session position
    // (spine index + column fraction) rather than falling back to whatever
    // was last persisted to HistoryEntry, which can be stale if the user
    // toggles modes before the debounced position save has flushed.
    window.honeycrispNavigateToChapterFraction = function(spineIndex, fraction) {
      var section = document.getElementById('hc-r' + spineIndex) || document.getElementById('chapter-' + spineIndex);
      if (!section) return;
      var rect = section.getBoundingClientRect();
      var top = rect.top + window.scrollY;
      var targetY = top + Math.max(0, Math.min(1, fraction)) * rect.height;
      window.scrollTo(0, Math.max(0, targetY));
    };

    window.honeycrispNavigateToFraction = function(fraction) {
      var maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      window.scrollTo(0, Math.max(0, Math.min(1, fraction)) * maxY);
    };

    window.honeycrispNavigateToSectionOffset = function(resource, targetOffset) {
      var section = document.getElementById('hc-r' + resource) ||
                    document.getElementById('chapter-' + resource);
      if (!section) {
        var sections = document.querySelectorAll('.hc-chapter, .ql-chapter');
        if (resource >= 0 && resource < sections.length) {
          section = sections[resource];
        }
      }
      if (!section) return;

      if (targetOffset <= 0) {
        var rect = section.getBoundingClientRect();
        window.scrollTo(0, Math.max(0, window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y));
        return;
      }

      var walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT, null);
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
      if (lastNode) {
        scrollNodeIntoPosition(lastNode, lastNode.length);
      } else {
        var rect = section.getBoundingClientRect();
        window.scrollTo(0, Math.max(0, window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y));
      }

      function scrollNodeIntoPosition(node, localOffset) {
        localOffset = Math.max(0, Math.min(node.length, localOffset));
        var range = document.createRange();
        range.setStart(node, localOffset);
        range.setEnd(node, localOffset);
        var rect = range.getBoundingClientRect();
        if (!rect || (rect.width === 0 && rect.height === 0 && rect.top === 0 && rect.bottom === 0)) {
          var parent = node.parentElement;
          if (parent) rect = parent.getBoundingClientRect();
        }
        var targetY = window.scrollY + rect.top - HONEYCRISP_POSITION_REFERENCE_Y;
        window.scrollTo(0, Math.max(0, targetY));
      }
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
      // Offset is at or past the end of the document: land on the last text node.
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
        window.webkit.messageHandlers.positionHandler.postMessage(window.honeycrispCurrentPosition());
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
      var sections = document.querySelectorAll('.hc-chapter, .ql-chapter');
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

}
