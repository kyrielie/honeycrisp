import CoreGraphics
import Foundation

/// Pure parts of paginated mode on the chapter host (roadmap M4, pass 7). No WebKit, no reader state, so the
/// hand-off rule and the geometry the reader derives from its settings can be tested directly.
enum ChapterHostPaging {
    /// Fallback viewport used before the window has a real layout pass, as `loadSpineItem` does for the
    /// merged document.
    nonisolated static let fallbackViewport = CGSize(width: 780, height: 920)

    /// Where a page turn past a chapter edge lands: the next chapter opens at its first column, the previous
    /// one at its last (same rule as `ReaderViewController.navigateSpine`). Nil when `index` is outside the
    /// book or there is no chapter in that direction.
    nonisolated static func handoff(
        from index: Int, forward: Bool, count: Int
    ) -> (index: Int, restore: RestorePosition)? {
        guard count > 0, (0..<count).contains(index) else { return nil }
        let target = index + (forward ? 1 : -1)
        guard (0..<count).contains(target) else { return nil }
        return (target, forward ? .start : .end)
    }

    /// Restore for a position read from the scroll window (contract C2): an exact text offset in `resource`.
    nonisolated static func restore(
        for position: ChapterHostSurface.Position
    ) -> (resource: Int, restore: RestorePosition) {
        (position.resource, .characterOffset(max(0, position.offset)))
    }

    /// Where a flag-mode paged load opens: the chapter and restore carried by an in-memory `Restore` (a scroll
    /// window position, a fraction, or the start), or `fallbackIndex` at its start when none is pending. The
    /// chapter is clamped into the book. Never reads saved history (roadmap M4 decision).
    nonisolated static func pagedTarget(
        for restore: ChapterHostSurface.Restore?, fallbackIndex: Int, count: Int
    ) -> (index: Int, restore: RestorePosition) {
        func clamp(_ index: Int) -> Int { min(max(index, 0), max(0, count - 1)) }
        switch restore {
        case .position(let position)?:
            let result = Self.restore(for: position)
            return (clamp(result.resource), result.restore)
        case .fraction(let resource, let fraction)?:
            return (clamp(resource), .fraction(fraction.isFinite ? fraction : 0))
        case .start?, nil:
            return (clamp(fallbackIndex), .start)
        }
    }

    /// True when following `target` from the document at `current` would replace the document (a different
    /// chapter or resource), false for a same-document fragment jump. Fragments are ignored.
    nonisolated static func changesDocument(from current: URL?, to target: URL) -> Bool {
        func stripped(_ url: URL) -> String {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
            parts.fragment = nil
            return parts.string ?? url.absoluteString
        }
        guard let current else { return true }
        return stripped(current) != stripped(target)
    }

    /// The column geometry for a viewport and the paging settings. An empty viewport falls back to
    /// `fallbackViewport`; negative margins and widths are raised to zero.
    nonisolated static func geometry(
        viewport: CGSize, cols: ColsPerScreen, paddingH: Int, paddingV: Int, maxWidth: Int
    ) -> ChapterHostPagedGeometry {
        let size = (viewport.width <= 0 || viewport.height <= 0) ? fallbackViewport : viewport
        return ChapterHostPagedGeometry(
            viewportWidth: size.width, viewportHeight: size.height, colsPerScreen: cols,
            paddingH: CGFloat(max(0, paddingH)), paddingV: CGFloat(max(0, paddingV)), maxWidth: CGFloat(max(0, maxWidth)))
    }

    /// Scroll window to paged (M4 pass 7.5): the chapter under the reference line opens at the column holding
    /// that text, by exact offset (decision B2). With no readable position the active scroll chapter opens at
    /// its start. The chapter is clamped into the book.
    nonisolated static func toPaged(
        from position: ChapterHostSurface.Position?, activeIndex: Int, count: Int
    ) -> (index: Int, restore: ChapterHostSurface.Restore) {
        guard let position else { return (clampedIndex(activeIndex, count: count), .start) }
        let index = clampedIndex(position.resource, count: count)
        return (index, .position(ChapterHostSurface.Position(resource: index, offset: max(0, position.offset))))
    }

    /// Paged to scroll window: the paged chapter reopens in the window at the offset of the first text on the
    /// page (decision B2), or at its start when the pager could not report one.
    nonisolated static func toScroll(
        index: Int, offset: Int?, count: Int
    ) -> (index: Int, restore: ChapterHostSurface.Restore) {
        let clamped = clampedIndex(index, count: count)
        guard let offset else { return (clamped, .start) }
        return (clamped, .position(ChapterHostSurface.Position(resource: clamped, offset: max(0, offset))))
    }

    private nonisolated static func clampedIndex(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(0, count - 1))
    }
}
