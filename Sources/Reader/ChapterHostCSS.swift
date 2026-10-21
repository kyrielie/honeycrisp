import Foundation

/// CSS for chapters served by `EPUBResourceSchemeHandler` (roadmap M3, contract C4). The book's own
/// stylesheets stay in the document; these two pieces come after them in source order:
///
/// - `stylesheet` is static, served as the `__app/reader.css` app resource and linked by `ServedChapter`.
/// - `userBlock(_:)` depends on settings, is inlined by `ServedChapter` as `<style id="honeycrisp-user">`
///   and is the only text a cosmetic patch has to replace.
///
/// Cascade design (proven by `ChapterHostCascadeTests`, not assumed):
/// - Reset rules sit in `@layer app-reset`, so any unlayered book rule beats them.
/// - Properties the user owns (font family, base size, text and background color, line height, link
///   color, width and margins, image containment, code font) use `!important`; descendants inherit them.
/// - Optional properties (alignment, hyphenation, paragraph spacing and indent, bold weight) use bare
///   element selectors without `!important`: a book class or inline style wins, a plain book element
///   rule loses on source order. They are emitted only when the user actually set them, because a rule
///   whose value means "book default" would still override the book's own `p` rule.
/// - Never touched: italics, bold on classes, small caps, underline, `white-space`, `display`,
///   direction, list styles, centered text.
enum ChapterHostCSS {
    static let stylesheet = """
        @layer app-reset {
            html { box-sizing: border-box; }
            *, *::before, *::after { box-sizing: inherit; }
            img, svg, video { height: auto; }
            pre { max-width: 100%; overflow-x: auto; }
            table { max-width: 100%; }
        }

        html {
            background-color: var(--reader-bg) !important;
            font-size: var(--reader-font-size) !important;
        }

        body {
            font-family: var(--reader-font-family) !important;
            color: var(--reader-text) !important;
            font-size: 1.1rem !important;
            line-height: var(--reader-line-height) !important;
            max-width: var(--reader-max-width) !important;
            margin: 0 auto !important;
            padding: 28px var(--reader-padding-h) 48px !important;
        }

        *, *::before, *::after {
            font-family: inherit !important;
            color: inherit !important;
            background-color: transparent !important;
            line-height: inherit !important;
        }

        a { color: var(--reader-link) !important; pointer-events: var(--reader-link-pointer-events); }
        code, pre { font-family: var(--reader-code-font-family) !important; }
        img, svg, video { max-width: 100% !important; }

        p { margin-block: 0 var(--reader-paragraph-spacing); }
        b, strong { font-weight: var(--reader-bold-weight); }
        """

    /// Variables for every setting, plus the optional rules that exist only while the setting is on.
    /// `EPUBParser.readerVarsCSS` stays the single definition of the variables.
    static func userBlock(_ cosmetics: ReaderCosmeticSettings) -> String {
        var css = EPUBParser.readerVarsCSS(cosmetics)
        if cosmetics.textAlignment != .book {
            css += "\np { text-align: var(--reader-text-align); }"
        }
        // Same condition as `--reader-hyphens: auto` in `readerVarsCSS`.
        if cosmetics.hyphenate, EPUBParser.sanitizedLanguageTag(cosmetics.language) != nil {
            css += "\np { hyphens: var(--reader-hyphens); -webkit-hyphens: var(--reader-hyphens); }"
        }
        if cosmetics.paragraphIndent != nil {
            css += "\np { text-indent: var(--reader-paragraph-indent); }"
        }
        return css
    }
}
