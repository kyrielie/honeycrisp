import Foundation

extension ChapterHostScript {
    /// Second half of `source`: windowing, position reporting, restore and the `honeycrispHost` export.
    static let sourceTail = #"""
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
          // Puts the restore target on the reference line (or the chapter top for a bare chapter).
          function place(target) {
            var slot = slotFor(target.resource);
            if (!slot) { return; }
            var top = slot.getBoundingClientRect().top + window.scrollY;
            if (target.offset !== null) { scrollTo(target.resource, target.offset); }
            else if (target.fraction !== null) {
              var height = slot.getBoundingClientRect().height;
              window.scrollTo(0, Math.max(0, Math.round(top + target.fraction * height - referenceY())));
            } else { window.scrollTo(0, Math.max(0, Math.round(top))); }
          }
          // While the shell is still loading, chapters measured late (or short at first) can change heights after the
          // placement. The target is placed once more when the shell has loaded, and the reveal waits for that.
          var settling = null;
          function performRestore() {
            var target = pending;
            pending = null;
            if (!target) { return; }
            place(target);
            emptyHeld = false;
            reconcile();
            if (document.readyState !== 'complete') { settling = target; } else { reveal(); }
            setTimeout(reportPosition, 0);
          }
          function settle() {
            fitAll();
            if (!settling) { return; }
            var target = settling;
            settling = null;
            place(target);
            reconcile();
            reveal();
            setTimeout(reportPosition, 0);
          }
          function restoreTo(resource, offset, fraction) {
            var slot = slotFor(resource);
            if (!slot) { reveal(); return false; }
            emptyHeld = true;
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
          restoring = document.body.hasAttribute('data-hc-restore-resource');
          frames().forEach(wire);
          if (restoring) {
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
          window.addEventListener('load', settle);
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
