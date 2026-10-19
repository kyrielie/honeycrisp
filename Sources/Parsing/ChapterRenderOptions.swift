import Foundation

/// Everything that changes what `EPUBParser.extractedChapterBody` returns for a spine item.
///
/// One value is built per render pass and handed to the scroll renderer, the paginated renderer, search
/// and speech, so the text those features index is the text the web view actually shows. Before this type
/// existed, search and speech hard-coded both flags to `false`, so their character offsets drifted from the
/// DOM whenever the user had a structural reading option on.
///
struct ChapterRenderOptions: Equatable {
    /// Strip leading space/tab runs inside paragraph-like elements.
    var removeParagraphIndents = false
    var fanficPreface = false
    var includeTitleBlock = true
    var plan: FrontMatterPlan?
    var meta: WorkMeta?

    /// No optional transformations. Used by tests and as the default for callers that do not care.
    static let plain = ChapterRenderOptions()

    static func current(from settings: SettingsManager, package: EPUBPackage? = nil, skin: ReaderSkin? = nil) -> ChapterRenderOptions {
        let identity = package.map(BookIdentity.detect)
        let enabled = settings.fanficPreface && package != nil
        let plan = enabled ? package.flatMap { FrontMatterPlan.detect(in: $0, identity: identity) } : nil
        let meta = enabled && plan != nil ? package.flatMap { WorkMetaExtractor.extract(from: $0, identity: identity) } : nil
        return ChapterRenderOptions(
            removeParagraphIndents: settings.removeParagraphIndents,
            fanficPreface: enabled && plan != nil && meta != nil,
            includeTitleBlock: !(skin?.template.contains("[[title]]") ?? false),
            plan: meta == nil ? nil : plan,
            meta: plan == nil ? nil : meta
        )
    }
}
