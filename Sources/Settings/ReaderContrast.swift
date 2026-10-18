import Foundation

/// Pure color math for the reader: WCAG relative luminance, contrast ratio, and the search-hit palette
/// derived from the page colors. No AppKit, so it can be unit-tested directly.
///
/// Inputs are CSS color strings read with the same semantics as `SettingsManager.color(fromCSS:)`:
/// six-digit hex with an optional leading `#`, anything else reads as black.
enum ReaderContrast {
    /// Search-hit colors as CSS values, emitted as `--reader-hit-*` variables by `readerVarsCSS`.
    struct HitColors: Equatable {
        var hitBackground: String
        var hitText: String
        var activeBackground: String
        var activeText: String
    }

    /// Minimum contrast ratio for text over a hit (WCAG AA for body text).
    static let minimumTextRatio = 4.5

    /// A page at or below this relative luminance counts as dark. 0.18 is close to the luminance where
    /// black and white text contrast equally, so it splits the range at the natural midpoint.
    static let darkPageLuminanceCeiling = 0.18

    private static let lightPageHit = (background: "#FFEE58", text: "#000000")
    private static let darkPageHit = (background: "#7A5F00", text: "#FFFFFF")

    /// Parsed `(red, green, blue)` components in 0...1. Anything that is not six hex digits is black.
    static func rgb(fromCSS css: String) -> (red: Double, green: Double, blue: Double) {
        var hex = css.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return (0, 0, 0) }
        return (
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// WCAG 2.x relative luminance, 0 (black) to 1 (white).
    static func relativeLuminance(ofCSS css: String) -> Double {
        let color = rgb(fromCSS: css)
        func linear(_ component: Double) -> Double {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG contrast ratio, 1 to 21, symmetric in its arguments.
    static func ratio(_ first: String, _ second: String) -> Double {
        let a = relativeLuminance(ofCSS: first)
        let b = relativeLuminance(ofCSS: second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Palette for search hits on a page with the given colors.
    ///
    /// A light page gets the classic yellow marker with black text. A dark page gets a deep amber with
    /// white text, so the marker does not glare. Text color is always explicit (hits no longer inherit
    /// the page's text color) and is checked against `minimumTextRatio`; if a candidate ever failed, the
    /// yellow marker with black text is used. The active hit keeps the system selection colors (the
    /// user's accent color) and is made distinct from other hits by an outline in the hit text color,
    /// which is applied in CSS.
    static func hitColors(background: String, text: String) -> HitColors {
        let isDarkPage = relativeLuminance(ofCSS: background) <= darkPageLuminanceCeiling
        var choice = isDarkPage ? darkPageHit : lightPageHit
        if ratio(choice.background, choice.text) < minimumTextRatio {
            choice = lightPageHit
        }
        return HitColors(
            hitBackground: choice.background,
            hitText: choice.text,
            activeBackground: "Highlight",
            activeText: "HighlightText"
        )
    }
}
