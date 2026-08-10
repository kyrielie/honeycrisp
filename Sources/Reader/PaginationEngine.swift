import AppKit
import WebKit

// MARK: - PaginationEngine
//
// Thin Swift coordinator for horizontal CSS multi-column paged mode. Ported from
// Ambrosia's PaginationEngine.swift, trimmed of everything specific to Ambrosia's
// multi-work library (spine maps across works, annotation/highlight offset
// bridging) — Honeycrisp has none of that.
//
// DESIGN — CSS pre-loaded, no Swift-side geometry math:
//   Column layout CSS is baked into the HTML string by ReaderViewController (via
//   EPUBParser.paginatedColumnCSS) before loadFileURL is ever called. By the time
//   webView(_:didFinish:) fires, column layout is already settled — there is no
//   post-load evaluateJavaScript race and no delay to wait out. This engine's job
//   is limited to: injecting PaginationJS, telling it how many columns fit on
//   screen, restoring the requested position once the total column count is
//   known, and exposing navigation/query methods.
//
//   Geometry (column width, column gap) is read by JS from
//   getComputedStyle(document.documentElement) — never passed in from Swift.
//
// RESIZE:
//   Because column CSS is baked into the HTML, a resize requires a full spine
//   reload with updated viewport geometry, not just re-running JS. See
//   ReaderViewController's resize handler, which reads currentFraction and calls
//   loadSpineItem(index:restorePosition:.fraction(_:)) again.
//
// KEY REPEAT SUPPRESSION:
//   Swift intercepts keyDown in ReaderWebView/ReaderViewController. The engine
//   exposes handleKeyDown(_:) which ReaderViewController calls directly — the
//   WKWebView never sees raw keystrokes. One physical keypress = one page turn.
//
// THREAD SAFETY: All public methods must be called on the main thread.

// MARK: - ColsPerScreen preference

enum ColsPerScreen: Int, CaseIterable {
    case one   = 1
    case two   = 2
    case three = 3

    var label: String {
        switch self {
        case .one:   return "1 column"
        case .two:   return "2 columns"
        case .three: return "3 columns"
        }
    }
}

// MARK: - RestorePosition
//
// .characterOffset is new relative to Ambrosia's RestorePosition — needed to
// satisfy Patch 0005's exact-offset restore contract on first open of a
// paginated book (Ambrosia restores by fraction only; Honeycrisp's history
// model stores an exact UTF-16 offset and this case is how paginated mode
// honors it).

enum RestorePosition {
    case start                     // column 0
    case end                       // last column
    case fraction(Double)          // 0.0–1.0, saved progress
    case characterOffset(Int)      // exact UTF-16 offset, from HistoryEntry
}

extension RestorePosition {
    /// JS statement that performs this restore. Baked by EPUBParser.
    /// buildPageHTML into an inline <script> that runs synchronously during
    /// HTML parse — before the WKWebView's first paint — so the correct
    /// column is already on screen for the very first frame rendered.
    ///
    /// This replaces an earlier approach where PaginationEngine.applyLayout
    /// drove the scroll itself from webView(_:didFinish:), via a Swift ->
    /// evaluateJavaScript round trip. That happens after the document has
    /// already had at least one opportunity to paint at column 0 (its
    /// default scroll position), so hiding the webview and revealing it
    /// after the fact couldn't reliably suppress the flash — WKWebView's
    /// compositor runs out-of-process and isn't guaranteed to have caught up
    /// to the scroll by the time the evaluateJavaScript completion handler
    /// (and thus the reveal) runs. Scrolling inline, before parsing yields
    /// control back to the run loop, removes the race entirely: there is no
    /// wrong frame to flash because column 0 is never actually painted.
    var bootstrapJS: String {
        switch self {
        case .start:
            return "window.qlScrollToColumn(0);"
        case .end:
            return "window.qlScrollToColumn(window.qlColumnCount() - 1);"
        case .fraction(let fraction):
            let clamped = max(0, min(1, fraction))
            return "window.qlScrollToFraction(\(clamped));"
        case .characterOffset(let offset):
            return "window.qlNavigateToOffset(\(offset));"
        }
    }
}

// MARK: - PaginationEngine

final class PaginationEngine: NSObject {

    // MARK: Callbacks

    /// Called after a spine finishes loading, CSS layout is already settled, and
    /// the requested restore position has been applied. Receives the total
    /// number of columns in the spine.
    var spineDidLoad: ((Int) -> Void)?

    /// Called when JS requests navigation to the next or previous spine item.
    var spineNavigationHandler: ((_ forward: Bool) -> Void)?

    /// Called after every column navigation (page turn or restore).
    var positionDidChange: ((_ column: Int, _ total: Int) -> Void)?

    // MARK: State

    private weak var webView: WKWebView?
    private var colsPerScreen: Int = 1
    private(set) var isReady = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func setColsPerScreen(_ cols: ColsPerScreen) {
        colsPerScreen = cols.rawValue
    }

    // MARK: Called from webView(_:didFinish:) — after CSS is already applied

    /// Reads back the column/total that the inline bootstrap script (see
    /// RestorePosition.bootstrapJS, embedded by EPUBParser.buildPageHTML)
    /// already scrolled to during HTML parse. Does not perform any scrolling
    /// itself — by the time didFinish fires and this runs, restore has
    /// already happened.
    func applyLayout(restorePosition: RestorePosition) {
        guard let webViewRef = webView else { return }
        isReady = false

        webViewRef.evaluateJavaScript("window.qlPaginationMetrics();") { [weak self] result, error in
            guard let self else { return }
            self.isReady = true

            guard error == nil,
                  let str = result as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                self.spineDidLoad?(1)
                return
            }

            let totalCols = (json["columns"] as? NSNumber)?.intValue ?? 1
            let column = (json["column"] as? NSNumber)?.intValue ?? 0

            self.positionDidChange?(column, totalCols)
            self.spineDidLoad?(totalCols)
        }
    }

    /// Reads the current progress fraction. Used before a resize-triggered spine
    /// reload, so the reload can request .fraction(f) as its restore position.
    /// Does NOT reapply layout itself.
    func currentFraction(completion: @escaping (Double) -> Void) {
        guard isReady, let webViewRef = webView else { completion(0); return }
        webViewRef.evaluateJavaScript("window.qlProgressFraction();") { result, _ in
            completion((result as? Double) ?? 0)
        }
    }

    // MARK: Navigation

    enum NavigationKey { case forward, backward }

    func handleKeyDown(_ key: NavigationKey) {
        guard isReady else { return }
        switch key {
        case .forward:  webView?.evaluateJavaScript("window.qlNextPage();", completionHandler: nil)
        case .backward: webView?.evaluateJavaScript("window.qlPrevPage();", completionHandler: nil)
        }
    }

    func scrollToColumn(_ column: Int) {
        guard isReady else { return }
        webView?.evaluateJavaScript("window.qlScrollToColumn(\(column));", completionHandler: nil)
    }

    func scrollToFraction(_ fraction: Double) {
        guard isReady else { return }
        let clamped = max(0, min(1, fraction))
        webView?.evaluateJavaScript("window.qlScrollToFraction(\(clamped));", completionHandler: nil)
    }

    func scrollToOffset(_ charOffset: Int) {
        guard isReady else { return }
        webView?.evaluateJavaScript("window.qlNavigateToOffset(\(charOffset));", completionHandler: nil)
    }

    func queryProgress(completion: @escaping (_ fraction: Double, _ column: Int, _ total: Int) -> Void) {
        guard isReady, let webViewRef = webView else { completion(0, 0, 1); return }
        let progressJS = """
        JSON.stringify({
            f: window.qlProgressFraction(),
            c: window.qlCurrentColumn(),
            t: window.qlColumnCount()
        });
        """
        webViewRef.evaluateJavaScript(progressJS) { result, _ in
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
            else { completion(0, 0, 1); return }
            completion(dict["f"] ?? 0, Int(dict["c"] ?? 0), Int(dict["t"] ?? 1))
        }
    }
}

// MARK: - ReaderViewController integration notes
//
// 1. MESSAGE HANDLER REGISTRATION
//    "pageAction" and "positionUpdate" are registered on
//    WKWebViewConfiguration.userContentController before the WKWebView is
//    constructed, in ReaderViewController.loadView() — additive to what's
//    already there for progressHandler/positionHandler (Patch 0005), same
//    pattern, not a new one. PaginationEngine does not register these itself.
//
// 2. NAVIGATION DELEGATE
//    In webView(_:didFinish:), when currentMode == .paginated:
//        paginationEngine.applyLayout(restorePosition: pendingRestorePosition)
//    The actual restore scroll already happened by this point — it runs
//    synchronously inline, during HTML parse, via a bootstrap <script> that
//    EPUBParser.buildPageHTML embeds using RestorePosition.bootstrapJS.
//    applyLayout only reads back the resulting column/total.
//
// 3. KEY REPEAT SUPPRESSION
//    NSEvent.isARepeat must be checked before forwarding to handleKeyDown(_:).
//    One physical keypress = one page turn.
//
// 4. RESIZE HANDLING
//    Debounce on view layout / window resize. Read paginationEngine's
//    currentFraction, then call ReaderViewController.loadSpineItem(index:
//    restorePosition: .fraction(f)) — a full spine reload, because the column
//    CSS is baked into the HTML.
//
// 5. SCROLLBAR SUPPRESSION
//    After the WKWebView is added to the view hierarchy (enclosingScrollView is
//    nil until then):
//        webView.enclosingScrollView?.hasHorizontalScroller = false
//        webView.enclosingScrollView?.hasVerticalScroller   = false
//        webView.enclosingScrollView?.horizontalScrollElasticity = .none
//        webView.enclosingScrollView?.verticalScrollElasticity   = .none
