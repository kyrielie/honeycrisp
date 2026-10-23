import Foundation
import WebKit

/// The L3 surface protocol representing a flowing reader surface (FRAMEWORK contract C5).
/// Concrete implementations include `ChapterHostSurface` (windowed iframe host behind `HONEYCRISP_CHAPTER_HOST=1`),
/// `LegacyMergedSurface` (the 2.2.1 merged-document render), and `FlowSurface` (roadmap M4a default).
@MainActor
protocol FlowingSurface: AnyObject {
    /// Content world where pagination scripts run: nil for merged document, `.defaultClient` for isolated surfaces.
    var pagerContentWorld: WKContentWorld? { get }

    /// Whether this surface supports reading position bookmarks.
    var supportsBookmarks: Bool { get }

    /// Whether reading progress is persisted to HistoryManager.
    var persistsProgress: Bool { get }

    /// Whether reading position is persisted to HistoryManager.
    var persistsPosition: Bool { get }

    /// Whether spine navigation requires paginationEngine.isReady == true.
    var requiresEngineReadyForSpineNavigation: Bool { get }

    /// Whether this surface manages scroll-mode windowing/rendering directly.
    var managesScrollWindow: Bool { get }

    /// Whether this surface manages paged-mode single-chapter loading directly.
    var managesPagedChapter: Bool { get }

    /// Whether this surface handles reading mode toggle internally.
    var handlesReadingModeToggle: Bool { get }

    /// Whether this surface handles structural settings reloads internally.
    var handlesStructuralReload: Bool { get }

    /// Whether this surface handles paginated resize debouncing internally.
    var handlesPaginatedResize: Bool { get }

    /// Installs configuration, scheme handlers, and user scripts into WKWebViewConfiguration before view creation.
    func install(into configuration: WKWebViewConfiguration)

    /// Applies cosmetic updates live without reloading the document.
    func applyCosmetics(_ cosmetics: ReaderCosmeticSettings, to webView: WKWebView, mode: ReadingMode) async throws

    /// Evaluates navigation policy for the given navigation action.
    func allowsNavigation(action: WKNavigationAction, currentURL: URL?) -> Bool

    /// Called when navigation finishes to perform surface-specific setup. Returns true if handled.
    func didFinishNavigation(in webView: WKWebView, paginationEngine: PaginationEngine?, colsPerScreen: ColsPerScreen) -> Bool

    /// Target spine index and restore position when restoring paginated mode.
    func targetForPaginatedRestore(fallbackIndex: Int, count: Int) -> (index: Int, restore: RestorePosition)?
}

/// Adapts the legacy 2.2.1 merged document path to `FlowingSurface` (contract C5).
@MainActor
final class LegacyMergedSurface: FlowingSurface {
    var pagerContentWorld: WKContentWorld? { nil }
    var supportsBookmarks: Bool { true }
    var persistsProgress: Bool { true }
    var persistsPosition: Bool { true }
    var requiresEngineReadyForSpineNavigation: Bool { false }
    var managesScrollWindow: Bool { false }
    var managesPagedChapter: Bool { false }
    var handlesReadingModeToggle: Bool { false }
    var handlesStructuralReload: Bool { false }
    var handlesPaginatedResize: Bool { false }

    func install(into configuration: WKWebViewConfiguration) {
        // Legacy merged path does not install scheme handlers or isolate scripts.
    }

    func applyCosmetics(_ cosmetics: ReaderCosmeticSettings, to webView: WKWebView, mode: ReadingMode) async throws {
        guard let cssLiteral = EPUBParser.javaScriptStringLiteral(EPUBParser.readerVarsCSS(cosmetics)) else { return }
        let js = """
            (function() {
              var el = document.getElementById('honeycrisp-vars');
              if (el) el.textContent = \(cssLiteral);
            })();
            """
        _ = try await webView.evaluateJavaScript(js)
        if mode == .scroll {
            _ = try? await webView.evaluateJavaScript("window.reportPageInfo && window.reportPageInfo();")
        }
    }

    func allowsNavigation(action: WKNavigationAction, currentURL: URL?) -> Bool {
        true
    }

    func didFinishNavigation(in webView: WKWebView, paginationEngine: PaginationEngine?, colsPerScreen: ColsPerScreen) -> Bool {
        false
    }

    func targetForPaginatedRestore(fallbackIndex: Int, count: Int) -> (index: Int, restore: RestorePosition)? {
        nil
    }
}

extension ChapterHostSurface: FlowingSurface {
    var pagerContentWorld: WKContentWorld? { .defaultClient }
    var supportsBookmarks: Bool { false }
    var persistsProgress: Bool { false }
    var persistsPosition: Bool { false }
    var requiresEngineReadyForSpineNavigation: Bool { true }
    var managesScrollWindow: Bool { true }
    var managesPagedChapter: Bool { true }
    var handlesReadingModeToggle: Bool { true }
    var handlesStructuralReload: Bool { true }
    var handlesPaginatedResize: Bool { true }

    func applyCosmetics(_ cosmetics: ReaderCosmeticSettings, to webView: WKWebView, mode: ReadingMode) async throws {
        try await applyCosmetics(cosmetics, to: webView)
    }

    func allowsNavigation(action: WKNavigationAction, currentURL: URL?) -> Bool {
        if case .paged = presentation, action.navigationType == .linkActivated,
            let target = action.request.url, ChapterHostPaging.changesDocument(from: currentURL, to: target)
        {
            return false
        }
        if !Self.allowsNavigation(to: action.request.url) {
            return false
        }
        return true
    }

    func didFinishNavigation(in webView: WKWebView, paginationEngine: PaginationEngine?, colsPerScreen: ColsPerScreen) -> Bool {
        if case .paged = presentation {
            paginationEngine?.setColsPerScreen(colsPerScreen)
            paginationEngine?.applyLayout(restorePosition: .start)
        }
        return true
    }

    func targetForPaginatedRestore(fallbackIndex: Int, count: Int) -> (index: Int, restore: RestorePosition)? {
        let target = ChapterHostPaging.pagedTarget(
            for: pendingRestore, fallbackIndex: fallbackIndex, count: count)
        pendingRestore = nil
        return (target.index, target.restore)
    }
}
