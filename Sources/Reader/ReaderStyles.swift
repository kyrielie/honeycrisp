// ReaderStyles.swift
// Stylesheets, layout CSS, and variable blocks for reader surfaces (FRAMEWORK L3 Reader)

import Foundation

enum ReaderStyles {

    /// Font stack for `code` and `pre` when the theme font does not override them.
    static let monospaceStack = "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, monospace"

    static func sanitizedLanguageTag(_ value: String?) -> String? {
        EPUBParser.sanitizedLanguageTag(value)
    }

    /// The `:root` CSS custom properties, emitted into their own `<style id="honeycrisp-vars">`
    /// element so `applyCosmeticCSSUpdate` (in ReaderViewController) can replace just this
    /// element's textContent on a settings change, without touching the rest of the stylesheet.
    static func readerVarsCSS(_ cosmetics: ReaderCosmeticSettings) -> String {
        let paragraphIndentVariable = cosmetics.paragraphIndent.map {
            "--reader-paragraph-indent: \(ReaderCSSSanitizer.paragraphIndent($0))em;"
        } ?? ""
        return """
        :root {
            color-scheme: light dark;
            --reader-font-size: \(cosmetics.fontSizePercent)%;
            --reader-font-family: \(cosmetics.fontFamily);
            --reader-code-font-family: \(cosmetics.overrideMonospace ? cosmetics.fontFamily : monospaceStack);
            --reader-text-align: \(cosmetics.textAlignment.cssValue);
            --reader-hyphens: \(cosmetics.hyphenate && sanitizedLanguageTag(cosmetics.language) != nil ? "auto" : "manual");
            --reader-paragraph-spacing: \(ReaderCSSSanitizer.paragraphSpacing(cosmetics.paragraphSpacing))em;
            \(paragraphIndentVariable)
            --reader-bold-weight: \(cosmetics.boldWeight.cssValue);
            --reader-bg: \(cosmetics.backgroundCSS);
            --reader-text: \(cosmetics.textCSS);
            --reader-link: \(cosmetics.linkCSS);
            --reader-hit-bg: \(cosmetics.hitBackground);
            --reader-hit-text: \(cosmetics.hitText);
            --reader-hit-active-bg: \(cosmetics.hitActiveBackground);
            --reader-hit-active-text: \(cosmetics.hitActiveText);
            --reader-line-height: \(cosmetics.lineHeight);
            --reader-max-width: \(cosmetics.maxWidth)px;
            --reader-padding-h: \(cosmetics.paddingH)px;
            --reader-link-pointer-events: \(cosmetics.allowLinkClicks ? "auto" : "none");
        }
        """
    }

    static func imageVisibilityCSS(hideImages: Bool) -> String {
        guard hideImages else { return "" }
        return "img, picture, svg image { display: none !important; }"
    }

    /// Horizontal CSS multi-column layout, ported from Ambrosia's
    /// ReaderPreferences.paginatedColumnCSS.
    // swiftlint:disable:next function_body_length function_parameter_count
    static func paginatedColumnCSS(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        colsPerScreen: ColsPerScreen,
        marginH: CGFloat,
        marginV: CGFloat,
        maxWidth: CGFloat
    ) -> String {
        let cols = colsPerScreen.rawValue
        let vw = Int(viewportWidth.rounded())
        let vh = Int(viewportHeight.rounded())
        let marginHInt = Int(marginH.rounded())
        let availableWidth = vw - 2 * marginHInt

        var colGap = max(1, Int((marginH * 2).rounded()))
        let colWidth: Int
        if cols <= 1 {
            colWidth = availableWidth
        } else {
            let raw = availableWidth + colGap
            let overhang = raw % cols
            if overhang != 0 { colGap += cols - overhang }
            colWidth = (availableWidth + colGap) / cols - colGap
        }

        let capSingleColumn = cols <= 1 && maxWidth < CGFloat(availableWidth)
        let bodyWidthCSS = capSingleColumn
            ? "max-width: \(Int(maxWidth))px !important; margin: 0 auto !important;"
            : "max-width: none !important; margin: 0 !important;"

        return """
        /* === Honeycrisp paginated layout === */
        html {
            width: \(vw)px !important;
            height: \(vh)px !important;
            max-width: \(vw)px !important;
            max-height: \(vh)px !important;
            min-width: \(vw)px !important;
            min-height: \(vh)px !important;
            padding-left: \(marginHInt)px !important;
            padding-right: \(marginHInt)px !important;
            padding-top: \(Int(marginV))px !important;
            padding-bottom: \(Int(marginV))px !important;
            column-width: \(colWidth)px !important;
            column-gap: \(colGap)px !important;
            column-fill: auto !important;
            overflow-x: scroll !important;
            overflow-y: hidden !important;
            scrollbar-width: none !important;
            box-sizing: border-box !important;
        }
        html::-webkit-scrollbar { display: none !important; }
        body {
            width: 100% !important;
            \(bodyWidthCSS)
            height: auto !important;
            overflow: visible !important;
            box-sizing: border-box !important;
        }
        body > *:first-child,
        body > div:first-child > *:first-child {
            break-before: avoid !important;
        }
        * {
            max-width: 100% !important;
            overflow-wrap: break-word !important;
            word-break: break-word !important;
        }
        """
    }

    static let readerCSS = """
    /* Search highlight colours */
    mark.ql-hit {
        background: var(--reader-hit-bg);
        color: var(--reader-hit-text);
        border-radius: 2px;
        padding: 0 1px;
    }
    mark.ql-hit.ql-active {
        background: var(--reader-hit-active-bg);
        color: var(--reader-hit-active-text);
        outline: 2px solid var(--reader-hit-text);
    }

    html {
        box-sizing: border-box;
        overflow-x: hidden;
        max-width: 100%;
        background-color: var(--reader-bg) !important;
        font-size: var(--reader-font-size);
    }

    *, *::before, *::after { box-sizing: inherit; }

    body {
        font-family: var(--reader-font-family) !important;
        color: var(--reader-text) !important;
        font-size: 1.1rem;
        line-height: var(--reader-line-height);
        padding: 0;
        margin: 0;
        background: transparent;
        overflow-x: hidden;
        max-width: 100%;
    }

    p {
        text-align: var(--reader-text-align);
        hyphens: var(--reader-hyphens);
        -webkit-hyphens: var(--reader-hyphens);
        margin-block-start: 0 !important;
        margin-block-end: var(--reader-paragraph-spacing) !important;
        text-indent: var(--reader-paragraph-indent);
    }

    p.ql-spacer { margin-block: 0 !important; height: 0; overflow: hidden; }
    [hidden] { display: none !important; }

    b, strong { font-weight: var(--reader-bold-weight); }

    #content { width: 100%; max-width: var(--reader-max-width); margin: 0 auto; padding: 28px var(--reader-padding-h) 48px; }
    .ql-chapter, .hc-chapter { margin: 40px 0; }
    .ql-chapter + .ql-chapter, .hc-chapter + .hc-chapter {
        border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent);
        padding-top: 40px;
    }

    img, svg, video, iframe { max-width: 100%; height: auto; display: block; margin: 1.2em auto; }

    h1, h2, h3, h4, h5, h6 {
        font-family: var(--reader-font-family) !important;
        line-height: 1.25;
        margin-top: 1.5em;
        margin-bottom: 0.5em;
    }

    blockquote {
        border-inline-start: 3px solid color-mix(in srgb, currentColor 20%, transparent);
        padding-inline-start: 12px;
        margin-inline: 0;
        color: color-mix(in srgb, currentColor 80%, black);
    }

    code, pre {
        font-family: var(--reader-code-font-family) !important;
        white-space: pre-wrap;
        word-break: break-all;
    }

    a { color: var(--reader-link); pointer-events: var(--reader-link-pointer-events); }

    * {
        font-family: inherit !important;
        color: inherit !important;
        background-color: transparent !important;
    }

    img, svg { color: unset !important; }
    """
}
