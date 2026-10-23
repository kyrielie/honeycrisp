import Foundation

extension ChapterTransformOptions {
    /// Constructs chapter transform options matching the user preferences in SettingsManager.
    static func current(from settings: SettingsManager) -> ChapterTransformOptions {
        ChapterTransformOptions(
            formatAO3: settings.formatFirstChapter,
            markSpacers: settings.collapseSpacerParagraphs
        )
    }
}
