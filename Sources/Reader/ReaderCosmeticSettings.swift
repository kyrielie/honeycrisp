// ReaderCosmeticSettings.swift
// Reader cosmetic settings snapshot for styling and live appearance patches (FRAMEWORK L3 Reader)

import Foundation

/// Snapshot of the reader's cosmetic settings (font, size, theme colors,
/// spacing, link clicks) at a single point in time.
struct ReaderCosmeticSettings: Equatable {
    var fontSizePercent: Int
    var fontFamily: String
    var backgroundCSS: String
    var textCSS: String
    var linkCSS: String
    /// Search-hit palette (`ReaderContrast.hitColors`), emitted as `--reader-hit-*` so a theme change
    /// repaints hits through the live CSS patch without a reload.
    var hitBackground: String
    var hitText: String
    var hitActiveBackground: String
    var hitActiveText: String
    var speechSentenceBackground: String = "#0068DA2E"
    var speechWordBackground: String = "#0068DA66"
    var lineHeight: Double
    var maxWidth: Int
    var paddingH: Int
    var allowLinkClicks: Bool
    /// When true, `code` and `pre` use the theme font instead of the monospace stack.
    var overrideMonospace: Bool = true
    var textAlignment: ThemeTextAlignment = .book
    var hyphenate: Bool = false
    var language: String?
    var paragraphSpacing: Double = 1.0
    var paragraphIndent: Double?
    var boldWeight: ThemeBoldWeight = .book

    /// Default reader cosmetics matching the standard light theme.
    static var `default`: ReaderCosmeticSettings {
        ReaderCosmeticSettings(
            fontSizePercent: 100,
            fontFamily: "Georgia, serif",
            backgroundCSS: "#ffffff",
            textCSS: "#000000",
            linkCSS: "#0068da",
            hitBackground: "#ffee58",
            hitText: "#000000",
            hitActiveBackground: "#ffa000",
            hitActiveText: "#000000",
            speechSentenceBackground: "#0068DA2E",
            speechWordBackground: "#0068DA66",
            lineHeight: 1.6,
            maxWidth: 700,
            paddingH: 24,
            allowLinkClicks: true
        )
    }

    /// Every value passes through `ReaderCSSSanitizer`, so the initial render and the live patch both
    /// get valid CSS no matter what is persisted. Hit colors derive from the sanitized page colors.
    static func current(from settings: SettingsManager, language: String? = nil) -> ReaderCosmeticSettings {
        let background = ReaderCSSSanitizer.hexColor(settings.effectiveBackgroundCSS, fallback: ReaderCSSSanitizer.fallbackBackground)
        let text = ReaderCSSSanitizer.hexColor(settings.effectiveTextCSS, fallback: ReaderCSSSanitizer.fallbackText)
        let link = ReaderCSSSanitizer.hexColor(settings.effectiveLinkCSS, fallback: ReaderCSSSanitizer.fallbackLink)
        let hit = ReaderContrast.hitColors(background: background, text: text)
        let speech = ReaderContrast.speechColors(background: background, text: text, link: link)
        let speechSentence = ReaderCSSSanitizer.hexColorWithAlpha(speech.sentence, fallback: "#0068da2e")
        let speechWord = ReaderCSSSanitizer.hexColorWithAlpha(speech.word, fallback: "#0068da66")
        return ReaderCosmeticSettings(
            fontSizePercent: ReaderCSSSanitizer.fontSizePercent(settings.fontSizePercent),
            fontFamily: ReaderCSSSanitizer.fontFamily(settings.fontFamily),
            backgroundCSS: background,
            textCSS: text,
            linkCSS: link,
            hitBackground: hit.hitBackground,
            hitText: hit.hitText,
            hitActiveBackground: hit.activeBackground,
            hitActiveText: hit.activeText,
            speechSentenceBackground: speechSentence,
            speechWordBackground: speechWord,
            lineHeight: ReaderCSSSanitizer.lineHeight(settings.lineHeight),
            maxWidth: ReaderCSSSanitizer.maxWidth(settings.maxWidth),
            paddingH: ReaderCSSSanitizer.paddingH(settings.paddingH),
            allowLinkClicks: settings.allowReaderLinkClicks,
            overrideMonospace: settings.useThemeFontForCode,
            textAlignment: settings.textAlignment,
            hyphenate: settings.hyphenate,
            language: language,
            paragraphSpacing: settings.paragraphSpacing,
            paragraphIndent: settings.paragraphIndent,
            boldWeight: settings.boldWeight
        )
    }
}
