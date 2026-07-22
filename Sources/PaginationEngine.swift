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
    private var pendingRestorePosition: RestorePosition = .start
    private(set) var isReady = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func setColsPerScreen(_ cols: ColsPerScreen) {
        colsPerScreen = cols.rawValue
    }

    // MARK: Called from webView(_:didFinish:) — after CSS is already applied

    /// Injects PaginationJS and restores the requested position. The column CSS
    /// is already baked into the loaded HTML, so no delay is needed to wait for
    /// layout to settle.
    func applyLayout(restorePosition: RestorePosition) {
        guard let webViewRef = webView else { return }
        isReady = false
        pendingRestorePosition = restorePosition

        let setupJS = """
        \(PaginationJS.script)
        window.qlSetup(\(colsPerScreen));
        window.qlPaginationMetrics();
        """

        webViewRef.evaluateJavaScript(setupJS) { [weak self] result, error in
            guard let self else { return }
            if error != nil {
                self.spineDidLoad?(1)
                return
            }

            var totalCols = 1
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cols = json["columns"] as? NSNumber {
                totalCols = cols.intValue
            }

            self.isReady = true

            switch self.pendingRestorePosition {
            case .start:
                self.scrollToColumn(0)
            case .end:
                self.scrollToColumn(totalCols - 1)
            case .fraction(let fraction):
                self.scrollToFraction(fraction)
            case .characterOffset(let offset):
                self.scrollToOffset(offset)
            }

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
//    pendingRestorePosition is set on ReaderViewController before loadFileURL is
//    called (see loadSpineItem).
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
