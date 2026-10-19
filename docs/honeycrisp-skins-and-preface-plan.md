# Honeycrisp: fanfic preface, source profiles and reader skins. Implementation plan (final)

Audience: the engineer implementing this. This document replaces `plan/honeycrisp-skins-and-preface-plan.md`, `IMPLEMENTATION-APPROACH.md` and `honeycrisp-plan-amendments.md`. All decisions are final. Open items are listed in section 12 with a verification step each.

Status: all five maintainer sign-offs (section 13) are approved. Amended after a corpus check of `Archive.zip` (random sample of 16, then all 188; results in 2.6 and the amendments in 8.1, 8.2 and section 12). The Honeycrisp license file must still be read before the first port commit (section 0), because it was not in the upload.

Scope: three features on one pipeline.

1. An optional Honeycrisp-generated preface that replaces the front matter of fanfiction EPUBs (AO3, FicHub, FicLab, WebToEpub), identical in layout across generators.
2. Small source profiles for defects seen in real EPUBs (Gutenberg, Standard Ebooks, Wikisource, fanfic whitespace).
3. NNW-compatible `.nnwtheme` skins (stylesheet and a minimal template) replacing Honeycrisp's `Theme` model and reusing the Nectar theme gallery.

## 0. Conventions

- Nothing here was built, compiled or run. All Swift and CSS below is a sketch. Do not claim a build or test passed unless it was run.
- `[V]` = verified by reading the named file in `honeycrisp-upload.zip` ("repo") or `honeycrisp-reference.zip` ("ref"). `[U]` = unverified, with the step that closes it.
- Line numbers are from the uploaded zip at HEAD `f16a97b` and will drift. Function names are authoritative.
- Repo rules (`CLAUDE.md`): read a file before editing it, no emojis or em-dashes in code or docs, settings change only through `SettingsManager` setters, EPUB content is untrusted (never interpolate into JS; use `EPUBParser.javaScriptStringLiteral`), no real EPUBs in the repo (synthetic fixtures only; `samples/` is local and untracked), one commit per phase unless noted, run `xcodegen generate` after adding files, update docs in the same change.
- `SettingsManager`, the Settings panes, `PaginationEngine` (beyond `RestorePosition`), `ReaderViewController` and the injected JS have no automated tests. State this in every PR that touches them.
- Commands: `xcodegen generate`, `./test.sh`, `swiftlint` on touched files only (CI does not run it).
- Ref paths below are relative to the ref zip root. Nectar paths are under `nectar/`, abbreviated `N/`: `N/Modules/AO3Kit/Sources/AO3Kit/` is `AO3Kit/`, `N/Modules/ArticleTheming/Sources/ArticleTheming/` is `Theming/`.
- Nectar is a fork of NetNewsWire, MIT licensed (`nectar/LICENSE`, `nectar/THIRD-PARTY-NOTICES.md`). Keep the notice for any copied text. Honeycrisp's own license file is not in the upload zip: check it before the first port commit.

## 1. Decisions (final)

| # | Decision | Reason |
|---|---|---|
| D1 | Preface is **parse then render** for every supported generator, never restyle in place (roadmap W14 approach B). | Four generators, four markups. One renderer gives identical output. |
| D2 | **Fail closed.** If extraction finds no title, no author, or no other field, the book is untouched. | A wrong guess is worse than the original preface. |
| D3 | The preface is **global, optional, default off**. It replaces the "Format for AO3" setting. | Per-book mode is a non-goal. The old setting does two unrelated things and one is a bug (V5). |
| D4 | **Spine items are never removed.** Extra front-matter items stay as hidden placeholders. | Saved positions, bookmarks, TOC links and scroll mode key on spine index. |
| D5 | Source detection keys on **generator and structure first, site second**. | "An AO3 book" is four file layouts. |
| D6 | Skins are `.nnwtheme` bundles: `Info.plist`, `stylesheet.css`, **and `template.html` rendered by a minimal macro substituter**. Gallery bundles load unchanged. | Evidence (section 2.5): all 188 corpus skins, the 10 bundled Nectar themes and Fimfiction use one 18-macro set, templates are at most 3,427 bytes, and only 5 of the 188 carry an inert `<script>` (stripped on load). Without the template, skin rules scoped to template-created wrappers (`.t`, `.rh`, `.hd`) never match. |
| D7 | Colors come from **literal `--nnw-bg`, `--nnw-ink`, `--nnw-link` tokens** in `:root` and the dark `:root`. **`--nnw-bg` is the page canvas** (what the `html` background and `ReaderContrast` use). A skin with no dark `:root` block is single-scheme: its light tokens are used in both modes (19 of the 188 corpus skins, for example Dracula and the three Rose Pine variants). A skin with no tokens at all (8 of 188; Nectar's `System` and `Reversi` also) is **not rejected**: see 8.1 for how it renders. A token that is present but not a literal `#RGB`/`#RRGGBB` is rejected (0 of 188 skins). Contrast: warn below 4.5:1, reject below 1.5:1 (Nectar's own floor). | Matches Nectar's documented contract (`nectar/docs/nnwtheme-format.md`: page color is the body background, tokens are an optional convenience; ink must contrast at 1.5 or more). Commodore 64 measures 2.26 (light) and 2.74 (dark) by design, so a 4.5 reject would drop it. All 188 corpus skins and all 10 bundled Nectar themes import. |
| D8 | User **overrides are global**, not per-skin, appended last. | Matches `ArticleThemeOverrides` (`Theming/ArticleThemeOverrides.swift`). |
| D9 | **Layout 2.** Scroll mode saves `activeScrollSpineIndex` plus a chapter-local offset. `EPUBAnchor.currentLayout` becomes 2. Layout-1 entries restore through the legacy path once (section 4.2). | Scroll-mode positions are whole-document today (V1a). Preface and `<style>` stripping would shift them. |
| D10 | Inline `style=` cleanup removes only `color`, `background`, `background-color`, `font-family`. | Wikisource uses 383 inline `font-size` values for structure. |
| D11 | No network in v1: no font download, no remote `@import`, no URL scheme, no archive downloader. Local import of `.nnwtheme.zip` and `.nnwtheme` folders only. | First network code is a product boundary. |
| D12 | The `*` reset is **demoted to a zero-specificity rule**, not deleted (section 8.3). | Skins win by order; presentational hints stay neutralized. |
| D13 | Bundled skins: Original, Quiet, Paper (equivalents of today's seeds) and a Honeycrisp variant of Fimfiction. Other gallery skins are installed through Import. | Keeps app size small; the gallery stays the single catalog. |
| D14 | Phases ship in this order: 0a, 0b, 1, 2, 3, 4a to 4d. | Preface is the explicit ask; skins depend on the reset change and position fix. |

## 2. Verified facts

### 2.1 The corpus (ref `samples-local-only/`, 13 EPUBs, local only, never commit)

| Generator | Spine front matter | OPF signals | Markup |
|---|---|---|---|
| Native AO3 (`ao3.epub`, Calibre 6.13) | 2 items: `split_000` (message and `dl.tags`), `split_001` (title, byline, Summary, Notes) | publisher "Archive of Our Own", subject "Fanworks", flat subjects, `dc:description` escaped HTML | `div#preface`, `p.message`, `dl.tags`, `div.byline`, `blockquote.userstuff`, `h2.toc-heading`, `div#chapters`, `div#afterword`, per-book `calibreN` classes |
| FicHub (AO3, FFN) | `introduction.xhtml` and `nav.xhtml` (a linear spine item) | only `generator` "Ebook-lib", opaque id, `dc:description` | zero classes; source URL only in text ("Original source: URL") |
| FicLab (AO3, FFN, Fimfic) | `cover`, `title`, `copyright`, `toc`, `summary` | `dc:identifier` `ficlab:...`, `dc:source` URL, flat `dc:subject`, `dcterms:issued/modified` | `fl-title`, `fl-summary`, key/value summary page |
| WebToEpub (AO3) | `0000_Information.xhtml` | `dc:source` URL only | `dl.work.meta.group`, `userstuff`, kudos/hits |
| Native Fimfiction (`fimfic.epub`) | n/a | publisher "Fimfiction" | not in the detection table: `unknown`, untouched |
| Gutenberg (2) | n/a | `dc:source` gutenberg.org | `pg-boilerplate`, `pagenum`, `sidenote`, 235 `&nbsp;` in one file |
| Standard Ebooks (2) | n/a | publisher "Standard Ebooks" | verse as `span.i1/.i2` plus `<br/>` |
| Wikisource | n/a | `dc:source` wikisource.org | 383 inline `font-size`, a `visibility:hidden` div, 17 body `<style>` elements |

`.azw3`, `.mobi`, `.html`, `.txt` are out of scope.

### 2.2 Native AO3 anatomy `[V]` (spine ids checked in `ao3.epub`)

```
split_000: id="preface"                      (h2.toc-heading "Preface", p.message, dl.tags)
split_001: id="preface" and id="chapters"    (title, byline, Summary, Notes; the chapters div is EMPTY)
split_002: id="chapters" and id="afterword"  (the work text; the afterword div is EMPTY)
split_003: id="afterword"                    (h2.toc-heading "Afterword", p.message)
NCX: Preface -> 000, <work title> -> 002, Afterword -> 003   (001 has no entry)
```

- `dl.tags` rows: Rating, Archive Warning, Category, Fandom, Relationships, Characters, Additional Tags, Language, Stats. Values are `<a>` links. Stats is one `dd` with `Published: ... Words: ... Chapters: n/m`.
- Authors' spacing is `<p> </p>` spacer paragraphs.
- Stable hooks: `id`s above, `dl.tags`, `p.message`, `.byline`, `blockquote.userstuff`. Never key on `calibreN`.
- Consequence: `id="chapters"` and `id="afterword"` each appear in files that are not chapters or back matter. Roles must use the rules in 5.2.

### 2.3 Honeycrisp code facts

| ID | Fact | Where |
|---|---|---|
| V1 | Paginated offsets are per spine item (`TreeWalker` rooted at `document.body`, which holds one item). Scroll-mode **bookmarks and search jumps** are chapter-local (rooted at `#chapter-N`). | `EPUBParser.readerJS`: `honeycrispCurrentChapterCharacterOffset`, `honeycrispNavigateToChapterOffset` |
| V1a | Scroll-mode **saved position** is whole-document: `spineIndex` 0 plus `honeycrispCurrentCharacterOffset()` over `document.body`. Restore is `scrollRestoreBootstrapJS` then `honeycrispNavigateToOffset(saved.characterOffset)` regardless of `spineIndex`. | `ReaderViewController`: `didReceivePosition`, `flushPositionSave`, `scheduleStructuralReload` (l.1210, 1250, 1269 write `currentMode == .scroll ? 0 : currentSpineIndex`); `scrollRestoreBootstrapJS` l.550-560 |
| V1b | `honeycrispCurrentCharacterOffset` returns `scrollY / scrollHeight * 1e6` when the caret is not over a text node, and that fraction is stored as a character offset. `honeycrispCurrentChapterCharacterOffset` returns the whole section length when the caret is outside the section. | `EPUBParser.readerJS` |
| V2 | Search and speech call `extractedChapterBody(... formatFirstChapter: false, removeParagraphIndents: false)`; the renderer passes the user's settings. With either on, DOM text and search text differ. | `EPUBParser` l.235-237, 263-268 vs `ReaderViewController` l.520-528, 590-604 |
| V3 | `searchableText(fromHTML:)` decodes only `&nbsp; &amp; &lt; &gt; &quot; &#39; &apos;` and numeric references. Emitted HTML must stay in that set. | `EPUBParser.searchableText` |
| V4 | Extraction strips no `<style>`, `<script>`, `style=` or `on*=`. `searchableText` drops `<style>/<script>` text but the DOM walker counts it. | `extractBody`, `extractedChapterBody`, `rewriteResourceURLs` |
| V5 | `applyFirstChapterFormatting` deletes **every** `h2.toc-heading` and keys on the per-book `calibre2` class. | `EPUBParser.applyFirstChapterFormatting` |
| V6 | Paginated progress excludes one first and one last spine item when `formatFirstChapter` is on. Native AO3 has two front items. | `reportPaginatedProgress` l.1333-1349 |
| V7 | `applyCosmeticCSSUpdate` patches `#honeycrisp-vars` and recomputes page info in scroll mode only; paginated column CSS is baked in. | `ReaderViewController` l.1146-1165, 1544-1566; `PaginationEngine` l.24-26 |
| V8 | Paginated stepping is `currentSpineIndex +/- 1` with no skip logic. | `navigateSpine` l.926-931 |
| V9 | `honeycrispPageInfo` picks the last `.ql-chapter` whose `rect.top + scrollY <= viewTop + 1`. A `display:none` section reports top 0 and always qualifies. | `EPUBParser.honeycrispPageInfo` |
| V10 | Scroll mode builds one `.ql-chapter#chapter-i[data-chapter-index]` per spine item; paginated loads one item per page. Both go through `extractedChapterBody`. | `buildScrollHTML` l.433, `buildPageHTML` l.470-520 |
| V11 | `TOCParser.tocNodes` maps TOC URLs to spine indices by exact path. `startReadingNode` uses landmarks then filename/heading terms. `firstSpineIndex(afterCoverIn:)` feeds `skipCoverWhenOpening`. | `TOCParser` l.65-120 |
| V12 | http(s) link activation goes to `NSWorkspace.shared.open`; `allowLinkClicks` gates `pointer-events`. | `ReaderViewController` l.1820-1829 |
| V13 | `EPUBAnchor.currentLayout = 1`, `legacyLayout = 1`. `HistoryEntry.anchorLayout` and `ReadingBookmark.anchorLayout` decode with the legacy default. `HistoryManager.record` carries `anchorLayout` forward; only `updatePosition` re-stamps it. **Nothing reads the field.** `savedPosition(for:)` returns only `(spineIndex, characterOffset)`. | `PaginationEngine.swift` l.75-80; `HistoryManager.swift` l.26, 56, 111-118, 152; `ReadingBookmark.swift` l.13-41 |
| V14 | `EPUBPackage` carries only `title` and `author` from the OPF. | `EPUBParser.parseOPF` l.301-302 |
| V15 | "Format for AO3" and "Remove paragraph indents" live in `GeneralSettingsViewController` (l.316-345, handlers l.530-536, refresh l.579-580). Reset clears both at `SettingsManager` l.738-739. | `SettingsWindowController.swift`, `SettingsManager.swift` |
| V16 | `readerCSS` has `body { font-family: var(--reader-font-family) !important; color: var(--reader-text) !important }`, `h1..h6 { font-family: ... !important }`, `code, pre { font-family: ui-monospace, ... !important }`, `html { background-color: var(--reader-bg) !important }`, and ends with `* { font-family: inherit !important; color: inherit !important; background-color: transparent !important }`. By cascade, that `*` rule also beats the non-important `a { color: var(--reader-link) }`, so links likely render in body color today `[U: confirm in WKWebView]`. | `EPUBParser.readerCSS` l.1240-1295 |
| V17 | Sandbox on; entitlements contain only `com.apple.security.files.bookmarks.app-scope`. Target macOS 13.0. Only dependency: ZIPFoundation 0.9.20. | `Sources/EPUBReader.entitlements`, `project.yml` |
| V18 | Test helper `makeEPUBRoot(opfPath:includeContainer:opf:files:)` writes empty files. | `EPUBParserTests.swift` l.300 |
| V19 | Navigation funnel: `startReading`, `navigateChapter`, bookmark jump (l.770) and search result (l.1732) all call `navigate(to:offset:chapterLocalOffset:)`. Bypasses: `navigateSpine`, the initial index in `loadEPUB` (l.463-473), `goToChapterBeginning/End` (use `activeScrollSpineIndex`), `tocSidebar(_:didSelectEntry:)` l.1670 `[U: not read]`. `updatePageCountLabel` prints `currentSpineIndex + 1` over the raw spine count. | `ReaderViewController` |
| V20 | `Theme`, `ThemeColorSet` and the three seeds (Original `#ffffff/#000000/#0068da` light, `#1c1c1e/#e8e0d4/#5aa9ff` dark; Quiet; Paper) live in `SettingsManager` l.67-250. `ReaderCSSSanitizer.hexColor(_:fallback:)` and `fontFamily(_:fallback:)` exist. | `SettingsManager.swift`, `ReaderCSSSanitizer.swift` |

### 2.4 Nectar facts used `[V]` unless marked

- `AO3PrefaceRenderer.html(id:data:)` (`AO3Kit/AO3PrefaceRenderer.swift`) emits only `<div id='X'><dl class='tags'>...</dl></div>`. No message, title, byline, summary or notes. Rows: `<dt class='wide' data-kind='..'>` / `<dd ...>`; category values carry `data-value` slugs (`ff fm mm gen multi other`); stats are one `dt`/`dd` pair each; series rows are per-entry with `nectar-series:` links. Attributes use single quotes; text escaping is `& < >`; attributes add `&#39;`. Wrapper id is caller-supplied (`ao3Preface`, `ao3SyntheticPreface`). The module imports `RSParser`: Honeycrisp must not.
- `ArticleTheme.init` prepends `core.css` to every skin and falls back to the app default template, stylesheet and plist when a file is missing (`Theming/ArticleTheme.swift` l.69-125). `Shared/Article Rendering/core.css` carries the preface rules (`#ao3SyntheticPreface, #ao3Preface`, `dl.tags` grid, `dt.wide/dd.wide`, `--ao3-preface-*` fallbacks), `.articleBody p` driven by `--paragraph-spacing` and `--paragraph-indent`, `html, body { overflow-x: hidden }`, plus NNW footnote, annotation and series rules Honeycrisp does not need.
- `ArticleThemeOverrides.cssOverrideBlock(themeCSS:)` writes `--nnw-bg/--nnw-ink/--nnw-link` with `!important` on `:root` (and in a dark media block), plus `body, .articleBody` rules, `.articleBody p` margin and indent, justify and hyphenation scoped to `#bodyContainer #workskin`, and prose-link rules excluding `#ao3Preface a`, `#ao3SyntheticPreface a`, `#ao3SeriesFooter a` (`Theming/ArticleThemeOverrides.swift` l.226-434).
- Validators: `ArticleThemeArchiveValidator.validate(zipURL:)` / `validate(data:)` parse only the central directory and return `ValidatedArchive { bundleName, bundlePath, fileNames, totalUncompressedSize }`; limits `maxCompressedSize` 10,000,000 and `maxExpandedSize` 50 MiB; they throw `ArticleThemeDownloader.ArticleThemeDownloaderError` (replace with a local enum). `ArticleThemeBundleValidator.validate(directory:)` uses `lstat` and never follows links; `copyInstallableFiles(from:to:)` copies only the three theme files and `LICENSE*`/`NOTICE*`. Nectar extracts with a different library (`Zip.unzipFile`); Honeycrisp uses ZIPFoundation (2.6).
- `CSSImportExtractor.extract(from:)` returns `CSSImportExtraction` (`importCSS`, `remainingCSS`); pure Foundation. `ArticleThemePlist.lenient(from:)` decodes with every key optional.
- Nectar docs (`nectar/docs/nnwtheme-format.md`): inline `<script>` in a template is forbidden; `data-versal-target` and `data-chapter-divider*` are optional no-ops without Nectar's JS; `[[body]]` inside `#bodyContainer.articleBody` is required.

### 2.5 Template evidence for D6 `[V]`

Macros found by grep in every `template.html` (10 bundles plus Fimfiction): `body byline title preferred_link text_size_class` (all), plus `feed_link feed_link_title date_medium datetime_long` (Dark Academia, Night Amber, OLED Black, Solarized, Fimfiction), plus `dateline_style datetime_medium external_link external_link_label external_link_stripped` (Duskbloom, High Contrast, Midnight Blue, Reversi, System, with `feed_link`, `feed_link_title` on most). `Nectar` uses only `body byline preferred_link text_size_class title` (11,309 bytes, no other macro). No template contains `<script`. Sizes: eight are 395 to 597 bytes, `System` 2,512 (mostly a comment block), `Nectar` 11,309. The System template notes that a macro inside an HTML comment is substituted, so comments must be stripped before substitution.

Fimfiction (`skins/Fimfiction.nnwtheme`): `template.html` creates `.rh` (running head), `.t.t430` (the box), `header.hd`, `#bodyContainer.articleBody.bd`. Its stylesheet is 10,601 bytes. It uses `--nnw-bg` as the box surface and `--fx-page` for the page (lines 4-10, 28-29, 53, 98, 101-102), and two `[[font-size]]` macros at lines 120-121 inside the iOS-only `@supports` block.

### 2.6 Corpus review: 188 skins from the author's Nectar library `[V]` (`Archive.zip`, local only)

Tested with a script against the validator rules in 8.1. Results that shaped the plan:

| Check | Result |
|---|---|
| Files | 188 bundles, each with `Info.plist`, `stylesheet.css`, `template.html` (181 with `License.md`). Plist keys are only `Name`, `ThemeIdentifier`, `Version`, `CreatorName`, `CreatorHomePage`, plus `Family`/`FamilyVariant` on 4. No duplicate `ThemeIdentifier`. |
| Sizes | Stylesheet max 49,673 bytes (Hyperlegible, embedded font), then 43,795 (NewsFax), 31,331 (Matisse). Template max 3,427 (NewsFax). Both are far under the caps in 8.1. |
| Tokens | 180 have all three literals in `:root`; 8 have none (Appanoose, Biblioteca, Hyperlegible, NewsFax, Promenade, Sepia, Tiqoe Dark, Verdana Revival). None has a partial or malformed set. 19 token-bearing skins have no dark block (single-scheme). |
| Contrast | 3 of 360 token pairs are under 4.5: Beige Box light 4.4, Commodore 64 light 2.26 and dark 2.74. |
| Fonts | 180 skins `@import` from `fonts.googleapis.com` (every import in the set uses that host). Two skins embed fonts as `data:` URLs (Hyperlegible, NewsFax), which is the offline precedent for Phase 5. |
| `url(` | No remote `url()` outside `@import`. Fragment references exist (`url(#codexWobble)` in Illuminated Codex, an SVG filter) and `data:` URLs in 9 skins. |
| `html`/`body` rules | 0 skins set `position`, `transform`, `overflow` (non-`x`), `height`, `width` or `columns` on `html`/`body`. 88 set `max-width` on a `body` rule (strict count, compound selectors included; an earlier count of 113 was not reproduced), for example `max-width:44em`. |
| Templates | Macros in use: `body byline title preferred_link text_size_class feed_link feed_link_title date_medium date_long date_short datetime_long datetime_medium datetime_short dateline_style external_link external_link_label external_link_stripped avatar_src`. 5 contain a `<script>` (Appanoose, Kelmscott, NewsFax, Promenade, Vintage Letter Green); Nectar blocks scripts, so they are inert there. 8 use `<img src="[[avatar_src]]">` (Birdsite, Broadsheet, Ember, Hyperlegible, NewsFax, Promenade, Rose Pine, Watch Later). 2 carry literal external `href`s (Bridge Command, NewsFax). 2 embed inline `<svg>` (Illuminated Codex, Promenade). |
| `[[font-size]]` | In stylesheets of 127 skins, mostly inside the iOS-only `@supports`; Kelmscott uses it outside it (a text-size class block, l.397). Kelmscott also names `[[text_size_class]]` inside a CSS comment. |
| CSS features | `:has()` in 128 skins; no nesting, `@layer` or `@scope`. 3 skins (Broadsheet, NewsFax, Promenade) have a `prefers-color-scheme: light` block; none carries tokens. |
| Template structure | 24 distinct structures. 178 templates have a `<header>`; 10 do not (Aldine, Appanoose, Broadsheet, Deco Line, Kennerley, Marigold Press, NewsFax, Promenade, Rosarivo, Verdana Revival). 15 carry an `#nnwFooter`. 43 use `<article>`; 24 use a `<table>` in the header. All 188 contain `[[title]]`. |
| Paginated hazards | `.t { overflow: hidden }` in 113 skins. `position: fixed` pseudo-elements: Illuminated Codex (`html::before`) and Hung Dates (`.t422::before`). 0 use `position: sticky`, `100vh` or `background-attachment: fixed`. |
| Overlap | `Micropony.nnwtheme` is byte-identical to the Fimfiction skin (stylesheet and template; the plist differs only in `Name` and `ThemeIdentifier`). Fimfiction is already inside the 188. |
| Names | 5 folder names are NFD (Loteria, the three Rose Pine variants, Wiener Werkstaette) while the plist `Name` is NFC. |

## 3. Architecture

### 3.1 Pipeline at open

```
parseOPF -> EPUBPackage (+ publisher, sources, identifiers, generatorMeta, descriptionHTML, subjects, date, modified, language)
        -> BookIdentity.detect(package)             // generator + site, reads OPF + first spine items
        -> FrontMatterPlan.build(package, identity) // roles per spine index, or nil
        -> WorkMetaExtractor.extract(...)           // only if plan != nil
        -> package.fanfic = FanficBook(identity, plan, meta)   // computed once, immutable
render (scroll or paginated) -> ChapterRenderOptions -> extractedChapterBody(index, options)
page = SkinComposer(skin, template) wraps the chapter HTML (section 8.2)
```

Search and speech use the same `ChapterRenderOptions` factory as the renderer (D3, V2).

### 3.2 New and changed files

| File | Change |
|---|---|
| `Sources/Parsing/BookIdentity.swift` (new) | `BookGenerator`, `BookSite`, detection. |
| `Sources/Parsing/FrontMatterPlan.swift` (new) | Roles, `resolveVisible`, progress span, visible-position helpers. |
| `Sources/Parsing/WorkMeta.swift`, `WorkMetaExtractors.swift` (new) | Model, normalization, one extractor per generator. |
| `Sources/Parsing/FanficPrefaceRenderer.swift` (new) | HTML emission, escaping, summary sanitizer. Ported logic from `AO3Kit/AO3PrefaceRenderer.swift` and `AO3ChapterHTMLExtractor.swift` (`parseWorkHeader`); `AO3Kit/HTMLLiteTree.swift` is reference for how the extractor walks HTML. |
| `Sources/Parsing/ChapterRenderOptions.swift` (new) | Replaces the two Bool parameters. |
| `Sources/Parsing/SourceProfiles.swift` (new) | Profile CSS and class tagging (Phase 3). |
| `Sources/Skins/ReaderSkin.swift`, `SkinStore.swift`, `SkinLoader.swift`, `SkinValidator.swift`, `SkinTemplate.swift`, `SkinImport.swift` (new) | Phase 4a. Ports listed in 8.1. |
| `Sources/Skins/skin-base.css` (new resource) | Ported subset of Nectar `core.css` (section 8.2). |
| `Sources/Parsing/EPUBParser.swift` | `EPUBPackage` fields; `extractedChapterBody` signature, cut/primary handling, body `<style>/<script>/on*` strip; `buildScrollHTML`/`buildPageHTML` placeholders and skin slots; JS patches; `readerCSS` changes; `extractedChapterBody` and `searchableText` become `internal`. |
| `Sources/Parsing/TOCParser.swift` | Filter entries pointing at cut items; `startReadingNode` and `firstSpineIndex(afterCoverIn:)` use `resolveVisible`. |
| `Sources/Reader/ReaderViewController.swift` | Layout-2 save and restore; `resolveVisible` in `navigate(to:)`, `navigateSpine`, `loadEPUB`; `reportPaginatedProgress` span; `updatePageCountLabel`; flags replaced by options. |
| `Sources/Reader/PaginationEngine.swift` | `currentLayout = 2`. |
| `Sources/History/HistoryManager.swift`, `ReadingBookmark.swift` | `savedPosition(for:)` returns the layout; bookmark clamp. |
| `Sources/Settings/SettingsManager.swift` | New keys, migrations, reset; `Theme` removal in 4d. |
| `Sources/Settings/SettingsWindowController.swift` | Checkbox replacement; skin picker and Import in 4a/4d. |
| `Sources/Settings/ReaderCSSSanitizer.swift` | New clamps (indent, spacing 0 to 3 em); skin CSS validator hooks. |
| `Sources/Sidebar/ThemePopoverViewController.swift` | Lists skins (4d). |
| `Tests/HoneycrispTests/*` (new files) | Per phase. |

### 3.3 `ChapterRenderOptions`

```swift
struct ChapterRenderOptions: Equatable {
    var removeParagraphIndents: Bool
    var fanficPreface: Bool          // global toggle
    var includeTitleBlock: Bool      // true when the active skin template has no [[title]] (8.2)
    var plan: FrontMatterPlan?       // nil when detection failed or toggle off
    var meta: WorkMeta?
    static func current(from s: SettingsManager, package: EPUBPackage, skin: ReaderSkin) -> ChapterRenderOptions
}
// extractedChapterBody(from:index:base:options:)
```

## 4. Phase 0: foundations

### 4.1 Phase 0a (no visible change)

1. **`ChapterRenderOptions` refactor.** Behavior identical; search and speech now pass the user's settings.
2. **Test seams.** Make `EPUBParser.extractedChapterBody` and `searchableText(fromHTML:)` `internal`. Add a content-fixture helper beside `makeEPUBRoot` (V18).
3. **Offset test.** With `removeParagraphIndents` on, `searchableText(extractedChapterBody(options))` equals the text of the same HTML parsed by a small test-only collector. Then spike a WKWebView `TreeWalker` length test and keep it only if it runs in `tests.yml` `[U]`.
4. **Entity rule (V3).** Lint test: any HTML from the new renderer round-trips through `searchableText` to the intended plain text. Emit only `&amp; &lt; &gt;` in text and `&#39;` in attribute values.
5. **Body `<style>`, `<script>`, `on*=`.** In `extractedChapterBody`, remove those elements and attributes and neutralize `javascript:` hrefs (roadmap W2.6). Tests: Wikisource-style `<style typeof=...><![CDATA[...]]></style>` removed; `onclick` removed; legitimate `href` untouched.

Acceptance: existing tests pass; new tests fail before and pass after; no behavior change at defaults except item 5.

### 4.2 Phase 0b: layout 2 (own commit, ships alone)

Save side (`didReceivePosition`, `flushPositionSave`, `scheduleStructuralReload`):

- Scroll mode saves `spineIndex = activeScrollSpineIndex` and `characterOffset = honeycrispCurrentChapterCharacterOffset()`. Paginated mode is unchanged.
- Fix V1b in the same commit: when the caret is not over text (or outside the section), return a sentinel (`-1`); the Swift side skips that save and keeps the last good value. Never store a scaled fraction as an offset.

Restore side (`scrollRestoreBootstrapJS`, `navigate(to:)`):

| Saved entry | Mode now | Restore |
|---|---|---|
| layout 2 | scroll | `honeycrispNavigateToChapterOffset(spineIndex, offset)` |
| layout 2 | paginated | `loadSpineItem(index, .characterOffset(offset))` (unchanged) |
| layout 1, `spineIndex == 0` | scroll | legacy `honeycrispNavigateToOffset(offset)`, once. Exact unless the book had body `<style>/<script>` text or the preface toggle is on. |
| layout 1, `spineIndex > 0` | scroll | `honeycrispNavigateToChapterOffset(spineIndex, offset)` (this entry came from paginated mode; today's restore uses the wrong function, V1a) |
| layout 1 | paginated | unchanged, plus the preface clamp (6.2) |
| any | any | if the offset is past the end or the call fails, fall back to `readingProgressPercent` as a fraction of `scrollHeight` (scroll) or of the book (paginated) |

Then:

- `HistoryManager.savedPosition(for:)` returns `(spineIndex, characterOffset, anchorLayout)`. Update both callers (`loadEPUB`, `scrollRestoreBootstrapJS`).
- `EPUBAnchor.currentLayout = 2`; `legacyLayout` stays 1. `updatePosition` re-stamps layout 2 on the next save; `record` keeps carrying the old layout forward for books not reopened (V13).
- Bookmarks already store `anchorLayout`. Scroll-mode bookmarks were always chapter-local (V1), so layout 1 and 2 bookmarks resolve the same way; only the clamp in 6.2 applies.
- Tests (extend `RestorePositionTests`, `HistoryEntryTests`, `HistoryManagerTests`): `savedPosition` returns the layout; `record` carry-forward; the table above as pure decision-function tests (extract the decision into a pure `RestorePlan.choose(saved:mode:)`); sentinel save is skipped. State that the JS and `ReaderViewController` stay untested.
- Docs: rewrite `ARCHITECTURE.md` 5a around layout 2 and the legacy fallback.

## 5. Phase 1: preface model, extractors, renderer (no wiring)

### 5.1 Detection (`BookIdentity`, first match wins)

| Generator | Signals (lowercase compares) |
|---|---|
| `ao3Native` | First spine item has `id="preface"` and (`dl` class `tags` or `p.message` starting "Posted originally on"). Corroborate with publisher "Archive of Our Own". |
| `ficlab` | `dc:identifier` starts `ficlab:` or a spine body class `fl-title`, `fl-summary`, `fl-cover` |
| `fichub` | First or second spine text contains "Exported with the assistance of FicHub". `Ebook-lib` alone is not enough (U7). |
| `webToEpub` | A spine item has `dl` with classes `work meta group` |
| `gutenberg` | `dc:source` host `gutenberg.org` or class `pg-boilerplate` |
| `standardEbooks` | publisher "Standard Ebooks" or identifier host `standardebooks.org` |
| `wikisource` | `dc:source` host ends `wikisource.org` |
| `unknown` | everything else, including native Fimfiction |

`BookSite` is the first of: `dc:source`, a `url:` identifier, "Original source:" text (FicHub), "Posted originally on ... at URL" (native AO3). Hosts: `archiveofourown.org` AO3, `fanfiction.net` FFN, `fimfiction.net` Fimfiction; unknown hosts keep the host string. Extend `EPUBPackage` (V14) with optional fields using the existing `XMLDocument` plus `local-name()` XPath style.

### 5.2 `FrontMatterPlan`

```swift
enum SpineRole { case primaryPreface, cut, chapter, backMatter }
struct FrontMatterPlan {
    let roles: [SpineRole]
    func isHidden(_ i: Int) -> Bool
    func resolveVisible(from i: Int, forward: Bool) -> Int      // never returns a cut index
    var frontCount: Int; var backCount: Int
    func visibleOrdinal(of i: Int) -> (position: Int, total: Int)   // for the page label
}
```

| Generator | primaryPreface | cut | backMatter |
|---|---|---|---|
| ao3Native | first leading item with `id="preface"` | other leading items with `id="preface"` | trailing items where `id="afterword"` is the first body-level element and there is no `chapters` div |
| ficlab | first leading front item (`cover`) | `title`, `copyright`, `toc`, `summary` | none observed |
| fichub | `introduction` | `nav` | none |
| webToEpub | `0000_Information` (contains the `dl`) | none | none |

Rules:

- Only a contiguous leading run can be front matter. Roles come from structure (body class, `id`, `epub:type`, `<nav>`), never filenames or `calibreN`.
- Native AO3 chapter rule: an item is a chapter if its `chapters` div has non-whitespace text and the item has no `id="preface"`. `split_001` (empty `chapters`, has `preface`) is front. `split_002` (non-empty `chapters`, empty trailing `afterword`) is a chapter. `split_003` is back matter. Appendix A pins all four.
- If the run is empty or extraction fails, `plan == nil`. The synthesized preface lives in the primary item.

### 5.3 `WorkMeta`

```swift
struct WorkMeta: Equatable {
    var title: String
    var authors: [Person]                    // name plus optional https URL
    var siteLabel: String?                   // "Archive of Our Own", "FanFiction.net", "Fimfiction"
    var sourceURL: URL?
    var summaryHTML: String?                 // sanitized (5.5)
    var notesHTML: String?
    var rows: [Row]                          // ordered label, values (optional href), isWide, kind
    var stats: [(label: String, value: String)]
}
```

`rows` is ordered display data, not an AO3 schema. `kind` is derived from the `dt` label (Rating `rating`, Archive Warning `warning`, Category `category`, Fandom `fandom`, Relationships `relationship`, Characters `character`, Additional Tags `freeform`, Language `language`, Series `series`, Collections `collections`), matching Nectar's `AO3PrefaceRow.kind`. Wide rows: Fandom, Relationships, Characters, Additional Tags, Archive Warning.

### 5.4 Field mapping

| Field | ao3Native | webToEpub | ficlab | fichub |
|---|---|---|---|---|
| Title | `p.message > b` or `h1` | `h1` | OPF title | `h1` on intro |
| Author | `.byline a[rel=author]` text and href | `By`/OPF creator | OPF creator | "By: X" paragraph |
| Summary | "Summary" paragraph then `blockquote.userstuff` | `Summary:` | summary page "Description" | paragraph between byline and `Status:`; fallback OPF `dc:description` (double-escaped) |
| Notes | "Notes" then `blockquote.userstuff` | `Notes:` | none | none |
| Rows | all `dl.tags` pairs with hrefs | `dl.work.meta.group` pairs | one `Tags:` row (flat, filtered) plus `Rating:` | FFN: Rated, Language, Genre, Characters; AO3: none |
| Stats | parse the Stats `dd` tokens | Published, Words, Chapters, Comments, Kudos, Bookmarks, Hits | published, updated, words, chapters, status | Status, Published, Updated, Words, Chapters, Reviews, Favs, Follows |

Rules:

- Reuse an AO3 label only when semantics match exactly (Rating, Fandom, Characters, Language). FFN "Genre" stays "Genre".
- Do not split ficlab's flat tag list. Filter injected values: the one equal to Status, `Fanfiction`, the site name.
- FicHub FFN stats are one paragraph "Rated: .. - Language: .. - Genre: .. - Characters: .. - Reviews: .. - Favs: .. - Follows: ..": parse by label regex, never by splitting on " - " (character lists contain hyphens).
- Dates: `YYYY-MM-DD`; for OPF ISO values take the first 10 characters. Prefer text-page dates for FicHub.
- FicHub `dc:description` is double-escaped: XML-decode once, then run the sanitizer.
- HTML parsing: `XMLDocument(data:options:)`, then `.documentTidyXML`, else fail closed. FicHub `introduction.xhtml` contains `<p/>` and a `<!DOCTYPE html>`: test that it parses before relying on it (U9).
- Series (`Part N of <a>`): not in the corpus (U2). Preserve a `Series:` row verbatim as text and link; no `nectar-series:` navigation.

### 5.5 Renderer

Port **row logic only** from `AO3Kit/AO3PrefaceRenderer.swift` (`html(id:data:)`, `renderedEntry`, `renderedCategoryEntry`, `kindAttribute`, the category slug map, `escape`, `escapeAttribute`). Drop the series-navigation branch, `seriesFooterHTML` and the `nectar-series:` helpers. Do not import `RSParser`. Add emitters for message, title, byline, summary and notes using the names the Fimfiction skin already styles (`div.byline`, `div.summary.module > h3.heading + blockquote.userstuff`, `div.notes.module`).

The wrapper id must be `ao3Preface` (Nectar `core.css`, the Fimfiction skin and the override generator all select it):

```html
<div id='ao3Preface' class='hc-preface'>
 <h1 class='heading'>Title</h1><div class='byline'>by <a rel='author' href='...'>Author</a></div>   <!-- only when options.includeTitleBlock -->
 <p class='message'>Posted originally on the <a href='https://archiveofourown.org/'>Archive of Our Own</a> at <a href='URL'>URL</a>.</p>
 <dl class='tags'><dt data-kind='rating'>Rating:</dt><dd data-kind='rating'><a href='...'>General Audiences</a></dd> ... <dt class='wide' data-kind='relationship'>Relationships:</dt><dd class='wide' data-kind='relationship'>...</dd> ... <dt>Published:</dt><dd>2022-05-12</dd></dl>
 <div class='summary module'><h3 class='heading'>Summary:</h3><blockquote class='userstuff'>...</blockquote></div>
 <div class='notes module'><h3 class='heading'>Notes:</h3><blockquote class='userstuff'>...</blockquote></div>
</div>
```

- The title block is emitted only when the active skin template has no `[[title]]` (the template header supplies title and byline otherwise, as in Nectar). Stats are one `dt`/`dd` pair per stat, as in Nectar, not the single bundled Stats cell.
- Compact HTML: no formatting whitespace between tags, so DOM text nodes equal `searchableText` output (V3).
- Escape every value with Nectar's escaper (`& < >`; attributes add `&#39;`). Attribute values are always quoted with single quotes.
- Hrefs: only `http`/`https`, parsed through `URL`; anything else becomes plain text. Links open externally through the existing delegate (V12).
- Site text: AO3 "Archive of Our Own", FFN "FanFiction.net", Fimfiction "Fimfiction", otherwise the host.
- Summary and notes are untrusted. A hand-written tokenizer (about 120 lines) allows `p br em strong i b u s blockquote ul ol li hr` and `a[href]` (http/https, `rel='noopener noreferrer'`), drops other tags but keeps their text, drops all other attributes, drops `<script>`/`<style>` with content, decodes entities and re-escapes.
- CSS for the preface comes from `skin-base.css` (8.2), not from a Honeycrisp-only `#hc-preface` block.

### 5.6 Tests (Phase 1)

All fixtures are synthetic with placeholder text ("Fixture Title", "Fixture Author"). Never commit real EPUBs.

- Detection: one fixture per generator; `unknown` for plain EPUBs and native Fimfiction; FicHub without the credit line is not detected.
- Plan: native AO3 yields `[primary, cut, chapter, back]` using Appendix A; FicLab five-item front; FicHub intro plus nav; WebToEpub single item; the `split_001` and `split_002` empty-div cases.
- Extractors: every field in 5.4; missing optional fields omit rows; malformed XHTML falls back to tidy then fails closed.
- Normalization: ISO slicing, flat-tag filter, double-escaped description, `&amp;` in tags, FFN stats by regex with hyphenated character names.
- Renderer: golden HTML per fixture; `<script>` in title and summary escaped; non-http hrefs become text; sanitizer allowlist; round trip through `searchableText`; title block present only when `includeTitleBlock`.
- Fail closed: no title, no author, or no other field returns nil.

Acceptance: pure-Swift tests only, no UI, no wiring; the feature is unreachable.

## 6. Phase 2: wiring, cut mechanism, setting

### 6.1 Rendering

In `extractedChapterBody`, if `options.fanficPreface` and `plan != nil`:

- `.primaryPreface`: return the renderer output instead of the extracted body (skip `stripPrefaceHeading` and old formatting).
- `.cut`: return `""`.
- `.backMatter`: render normally but drop only its `h2.toc-heading` inside `id="afterword"`. Never drop chapter headings (V5).
- `buildScrollHTML`: a cut item emits `<section class="ql-chapter hc-cut" id="chapter-i" data-chapter-index="i" hidden aria-hidden="true"></section>` so indices and ids stay stable (D4, V10). Add `.ql-chapter.hc-cut{display:none}`.
- `buildPageHTML`: a cut index is never loaded (6.2).
- Patch `honeycrispPageInfo` (V9): `if (sections[i].classList.contains('hc-cut')) continue;` inside the loop. `spineCount` stays the real spine length.

### 6.2 Navigation, TOC, restore (centralized)

Put `resolveVisible` in the choke point `navigate(to:offset:chapterLocalOffset:)` with a direction hint (`.forward`, `.backward`, `.neutral`). That covers `startReading`, `navigateChapter`, bookmark and search jumps (V19). Add explicit calls only at the bypasses:

- `navigateSpine`: step in the direction until `!plan.isHidden(next)`; stop at the ends.
- `loadEPUB` initial index and `firstSpineIndex(afterCoverIn:)`.
- `tocSidebar(_:didSelectEntry:)`: confirm it routes through `navigate(to:)`; if not, add the call.
- `goToChapterBeginning/End`: safe once `honeycrispPageInfo` skips cut sections; add a test.
- `updatePageCountLabel`: show `visibleOrdinal(of:)` over the visible total, not `currentSpineIndex + 1` over the raw count.

A cut target lands on the primary preface when the intent was "earlier", else on the next visible item.

TOC: in `tocNodes(for:package:)`, drop entries whose `spineIndex` is a cut item. The native "Preface" entry pointing at the primary item stays. `startReadingNode` may not return a cut item.

Restore clamp (layout 1 and 2): if the saved item is the primary preface or a cut item, restore to the start of the primary preface. Apply the same clamp to bookmarks whose `spineIndex` is cut or primary. Offsets in other items are unaffected (V1).

Search and speech use the same options (Phase 0a). Cut items yield empty text (the speech loop already skips empty text); the preface yields its own text.

### 6.3 Progress

Replace the single-bookend logic in `reportPaginatedProgress` (V6) with the plan span:

```swift
let front = plan?.frontCount ?? 0, back = plan?.backCount ?? 0
let effective = spineCount - front - back   // guard > 0
// index < front -> 0%, index >= spineCount - back -> 100%, else (index - front + withinFraction) / effective
```

Apply whenever detection produced a plan, independent of the toggle (it fixes a measurement error and changes no layout). If `plan == nil`, keep the old behavior only for users with `formatFirstChapter` on at migration time, then retire it. Scroll-mode progress is whole-document and unchanged.

### 6.4 Settings

- New key `readerFanficPreface` (Bool, default false); setter posts `.readerStructuralSettingsChanged`.
- Replace the "Format for AO3" checkbox and its hint with "Replace fanfiction preface" and the hint "Shows a standard preface built from the book's metadata for AO3, FicHub and FicLab files. Books that cannot be read this way are unchanged."
- Migration: `formatFirstChapter == true` maps to `readerFanficPreface = true` once; then ignore the old key and remove `applyFirstChapterFormatting`. Accept and document a one-time offset shift for users who had chapter headings stripped (V5).
- Reset clears the new key (`SettingsManager` l.738-739); update the refresh path (`SettingsWindowController` l.579-580).
- "Remove paragraph indents" stays until Phase 4c folds it into `paragraphIndent`.

### 6.5 Tests (Phase 2)

`resolveVisible` (forward, backward, ends, all hidden); a navigation-entry-point test that every public path returns a non-cut index for plans with cut items at start, middle and end; `buildScrollHTML` placeholders with stable ids; toggle off leaves HTML byte-identical to the previous output (golden); TOC filter and `startReadingNode`; progress arithmetic for native AO3 (`front 2, back 1, chapters 1`); restore and bookmark clamps; settings migration (state it has no automated coverage unless added).

Acceptance: with the toggle on, a native AO3 fixture shows one preface, no empty page when paging forward from it, consistent page and chapter counters, no TOC entry for the cut item. With it off, output is unchanged. Manual check in both modes on a Mac (V9 is the likely regression point).

## 7. Phase 3: source profiles

A profile is a small CSS block plus optional class tagging, chosen by `BookIdentity.generator`, injected as `<style id="honeycrisp-profile">` after skin CSS and before user overrides.

| Profile | Contents |
|---|---|
| fanfic common | Tag whitespace-only and nbsp-only `<p>` (`<p> </p>`, `<p>&nbsp;</p>`) with `class="hc-spacer"`; `p.hc-spacer{display:none}`. Attribute-only, so DOM text is unchanged (U8). |
| gutenberg | Mute `.pagenum` and `.sidenote` (`font-size:.75em;opacity:.55`). Do not hide: hidden text still counts in offsets and search. |
| standardEbooks | `p span.i1{padding-left:2em}` and `p span.i2{padding-left:3em}`. Standard Ebooks `local.css` uses `padding-left:2em;text-indent:-1em` with no `display` rule on `p span` `[V: local.css and se.css in standardebookcompatible.epub, per IMPLEMENTATION-APPROACH U5]`; spans are inline so `text-indent` has no effect. Honeycrisp loads no book CSS, so the profile supplies the padding. Confirm visually. |
| wikisource | Neutralize `.wst-dhr` visibility artifacts; rely on Phase 0a body `<style>` stripping. |

Profiles do not touch character offsets. Gutenberg `&nbsp;` indents stay as they are (revisit after W3.3 with samples). Tests: tagging regex (empty `<p/>` untouched; `<p> </p>` and `<p>&nbsp;</p>` tagged; text paragraphs untouched), profile selection by generator, golden CSS strings.

## 8. Phase 4: skins

### 8.1 Phase 4a: format, loader, validators, import

Bundle: `Name.nnwtheme/` with `Info.plist`, `stylesheet.css`, `template.html`; `License.md` is read for display only. Every missing file falls back to Honeycrisp's built-in default (same as `ArticleTheme.init`).

Port map (all sources in the ref zip):

| Honeycrisp need | Nectar source | How |
|---|---|---|
| `@import` strip | `Theming/CSSImportExtractor.swift`, tests `Tests/NetNewsWire-iOSTests/CSSImportExtractorTests.swift` | Copy; pure Foundation. Imports are stripped and ignored (D11). |
| `Info.plist` decode | `Theming/ArticleThemePlist.swift` (`lenient(from:)`) | Copy. |
| Archive safety | `Theming/ArticleThemeArchiveValidator.swift`, tests `ArticleThemeImportHardeningTests.swift` | Port; replace `ArticleThemeDownloaderError` with a local `SkinImportError`. |
| Folder safety | `Theming/ArticleThemeBundleValidator.swift` | Port (`validate(directory:)`, `copyInstallableFiles`). Used for folder imports and bundled skins. |
| Preface rows | `AO3Kit/AO3PrefaceRenderer.swift`, `AO3Kit/AO3ChapterHTMLExtractor.swift` | Phase 1. |
| Override CSS | `Theming/ArticleThemeOverrides.swift` | Reference for 8.4. Replace `#bodyContainer #workskin` with `#bodyContainer` (EPUBs have no `#workskin`). |
| Base CSS | `Shared/Article Rendering/core.css` | Subset (8.2). |
| Color extraction | `Theming/ArticleThemeColorExtractor.swift` | Not ported (UIKit, probe). Write the literal-token scan below. |
| Downloader | `Theming/ArticleThemeDownloader.swift` | Reference only (D11). |

Zip import (`.nnwtheme.zip`, `NSOpenPanel` and drag onto Settings):

1. `ArticleThemeArchiveValidator.validate(zipURL:)` port reads only the central directory (limits: 10,000,000 compressed, 50 MiB expanded) and returns the chosen bundle and kept file names.
2. Read the kept files **into memory** with ZIPFoundation: `Archive(url:accessMode: .read)`, `archive[path]`, then the consumer-based `archive.extract(_:bufferSize:skipCRC32:progress:consumer:)` (`Archive+Reading.swift` l.86; confirm trailing parameters). Entry inspection without extraction is confirmed: `Archive` is a `Sequence` of `Entry` with `path`, `type` (`.file`, `.directory`, `.symlink`) and `uncompressedSize`. No disk extraction, so no symlink or path-escape exposure.
3. Write the three files (canonical names) and `License.md` to `Application Support/Honeycrisp/Skins/<id>/` through `ArticleThemeBundleValidator.copyInstallableFiles` semantics.

Folder import and bundled skins go through `ArticleThemeBundleValidator.validate(directory:)`.

Token scan (`SkinValidator`): read `--nnw-bg`, `--nnw-ink`, `--nnw-link` literals from the top-level `:root` and from the `@media (prefers-color-scheme: dark)` `:root`.

- No dark block: the skin is single-scheme and its light tokens apply in both modes (not Original's dark values; Dracula and Rose Pine would otherwise get a white page in dark mode).
- All three tokens absent (`tokenless`, 8 of 188): mark `usesDefaultColors`. Do **not** emit the forced `html { background-color: var(--nnw-bg) !important }` for these skins, so the skin's own `html`/`body` background shows. Native chrome and `ReaderContrast` use Honeycrisp's default tokens until a one-shot runtime sample of `getComputedStyle(document.body).backgroundColor` (falling back to `html`) arrives from the page through a new `skinCanvasColor` message handler; cache it per skin and mode. This is a sample of the rendered page, not a theme probe, and applies only to tokenless skins.
- A token present but not `#RGB`/`#RRGGBB` rejects the skin with a user-visible reason.
- Pass values through `ReaderCSSSanitizer.hexColor(_:fallback:)`.

Scanner and validator implementation rules (found by running these rules over the corpus):

- Strip CSS comments first, then strip leading `@import` rules with a tokenizer that understands `url(...)` and quoted strings. Google Fonts imports contain semicolons (`wght@400;600`), so a regex ending at the first `;` leaves junk in front of the first rule and hides `:root`.
- Merge every top-level `:root` rule in order (Constructivist has two). Ignore `@supports` and `prefers-color-scheme: light` blocks when collecting tokens. Dark tokens come only from `:root` inside `@media (prefers-color-scheme: dark)`.
- The `url(` check must tokenize. A `url(%23n)` inside a quoted `data:image/svg+xml` string (Craft Table) is not a URL reference; only `url()` tokens outside strings count. Fragment references are accepted in both forms `#id` and `%23id`.
- `[[font-size]]` replacement and the "no `[[` remains" assertion both run after comment stripping (Kelmscott names `[[text_size_class]]` in a comment).

Validator (extend `ReaderCSSSanitizer`): reject `@import` that is not leading, `url(` with a scheme other than `data:` or a bare `#fragment` (SVG filters, as in Illuminated Codex), `</style`, `expression(`, `behavior:`, control characters, and skin rules on `html`/`body` that set `position`, `transform`, `overflow` (not `overflow-x`), `height`, `min-height`, `width` or column properties (`max-width` and `margin` are allowed: 88 corpus skins use `max-width` on `body`, and 0 set the rejected properties). Size caps: `stylesheet.css` 160 KB (corpus max 49,673; `High Contrast` is 100,388), `template.html` 16 KB (corpus max 3,427; `Nectar` is 11,309), `Info.plist` 16 KB. Contrast: WCAG ratio between `--nnw-ink` and `--nnw-bg` per mode when both are skin-supplied; below 4.5 shows a "low contrast" badge in the picker, below 1.5 rejects (pure helper, known-pair tests: black on white is 21, Commodore 64 light 2.26 warns but imports). The validator must not reject `[[`; the loader replaces every `[[font-size]]` in stylesheets with a literal `16` so no `[[` remains in active CSS (127 corpus skins use it; Fimfiction lines 120-121 sit in an iOS-only `@supports` block, and Kelmscott uses it in an active text-size class block).

Import normalization: normalize the bundle folder name and `Name` to NFC (5 corpus folders are NFD); identity is `ThemeIdentifier`, never the name; a duplicate `ThemeIdentifier` replaces the installed skin after confirmation. `Family` and `FamilyVariant` are read and kept for a later grouped picker (4 corpus skins use them).

`ReaderSkin { id, name, creator, version, css, template, tokens: ThemeColorSet (light, dark), usesDefaultColors: Bool }`. Store: bundled skins in the app bundle plus user skins in `Application Support/Honeycrisp/Skins/`; bundled ids are reserved. `ThemeIdentifier` is the id.

Template renderer (`SkinTemplate`), a pure string substituter:

- Validate: must contain `[[body]]` inside an element with `id="bodyContainer"` and class `articleBody` (Nectar contract), else the built-in default template is used.
- **Strip, do not reject, `<script>` elements** (5 of 188 skins carry one; Nectar blocks them, so they are inert there too). Reject (use default and report) a template containing `<iframe`, `<object`, `<embed`, `<link`, `<style`, `<meta`, `<base`, `on*=` attributes, `javascript:` or `data:` in any `href`, or a `src` other than `[[avatar_src]]`. `href` may be `#`, a macro, or a literal `https:` URL (Bridge Command and NewsFax carry fixed external links; they only open externally on an explicit click, V12). Inline `<svg>` is allowed (`<use>` and `<filter>` with fragment references only).
- Strip `<!-- ... -->` comments **before** substitution (the System template documents that macros in comments are substituted).
- Macros and values: `title` (OPF title, escaped), `byline` (HTML built by Honeycrisp from escaped author names, links http/https only), `preferred_link` and `feed_link` (source URL if http/https else `#`), `feed_link_title` (site label or host), `external_link` (same as source URL or empty), `external_link_label` (empty), `external_link_stripped` (source URL minus scheme), `dateline_style` (`articleDatelineTitle`), `date_*`, `datetime_*`, `time_*` (OPF date formatted `YYYY-MM-DD` or empty), `avatar_src` (a transparent 1x1 `data:image/gif` URI, so `<img src="[[avatar_src]]">` in Birdsite and Watch Later makes no request), `text_size_class` (empty), `body` (chapter HTML, unescaped). `external_link_label` is "Source" when a source URL exists, else empty. Unknown macros become empty strings. `#nnwFooter` markup that a stripped script would have hidden (Appanoose) shows as authored.
- `data-versal-target` and `data-chapter-divider*` attributes pass through and do nothing (no Nectar JS). Drop caps and chapter dividers are deferred (section 9).

Fimfiction (Honeycrisp variant, bundled; `skins/Fimfiction.nnwtheme` is the source): to satisfy D7, set `--nnw-bg` to the page color (`#eee9e2` light, `#1d232d` dark), add `--fx-box` (`#fff`, `#29313f`) and use it where the box surface is meant (`.t` at l.53, the `hr::after` background at l.98), and point `html` and `body` (l.28-29) at `--nnw-bg`, removing `--fx-page` (l.10, 102). Update the header comment (l.4-5). Keep the template unchanged. A user background override recolors `--nnw-bg` and the page, not `--fx-box`; skins with a separate surface should derive it from `--nnw-bg` with `color-mix` if they want it recolored. Document this in the skin authoring notes.

Tests: loader (valid, missing plist, missing template, missing stylesheet, missing tokens uses defaults, present-but-bad token rejected); token scanner (light and dark, missing dark); validator (each rejection rule plus an acceptance fixture); import hardening (path escape, symlink entry, oversize, duplicate entries, no bundle folder) using ported cases from `ArticleThemeImportHardeningTests.swift`; template (comment stripping, unknown macros, rejected tags, fallback, macro escaping); contrast helper. Corpus test: a skipped-by-default test (`HONEYCRISP_SKIN_CORPUS=<dir>`) loads every `.nnwtheme` in a local folder through the folder path and asserts zero rejections, that all 8 tokenless skins load as `usesDefaultColors`, that the 19 single-scheme skins reuse light tokens in dark mode, and that no `[[` remains in any loaded stylesheet after comment stripping. Add synthetic fixtures for a semicolon inside an `@import` URL, two `:root` rules, a light-scheme media block, and a data-URI containing `url(%23n)` (Appendix A). Run it locally against `Archive.zip` and the Nectar `Themes/` folder; never commit the bundles (the Honeycrisp repo bundles only the four in D13). CI uses the synthetic fixtures in Appendix A.

### 8.2 Phase 4b: page composition and the reset

Cascade inside the document, earliest first:

1. `readerVarsCSS` variables
2. `readerCSS` structure (with the changes in 8.3)
3. `skin-base.css` (Honeycrisp-owned subset of Nectar `core.css`)
4. skin CSS (`@import` stripped, `[[font-size]]` replaced)
5. profile CSS (Phase 3)
6. user overrides (8.4)

`skin-base.css` contents (ported from `Shared/Article Rendering/core.css`, keep the notice):

- The `#ao3Preface` block (margin, border-bottom via `--ao3-preface-border-color`, background, `font-size: var(--ao3-preface-font-size, 0.9em)`, color), `dl.tags` grid (`grid-template-columns: auto 1fr`), `dt` (weight 600, nowrap, `--ao3-preface-label-color`), `dd` (margin 0), `dt.wide`/`dd.wide` (`grid-column: 1 / -1`, `dt.wide` `white-space: normal`). Selectors use `#ao3Preface` only (no `#ao3SyntheticPreface`).
- `.articleBody p { margin-top: 0; margin-bottom: var(--paragraph-spacing, 1em); text-indent: var(--paragraph-indent, 0) }`. Reconcile with the existing paragraph rules in `readerCSS` so the default look is unchanged.
- Omitted deliberately: scrollbar-gutter, newsfoot footnote popovers, annotation `mark.nnw-highlight`, series footer and `nectar-series` styles, ad-blocking rules.

Composition:

1. Render the skin template around the chapter HTML. **Scroll mode:** wrap the whole document once; `[[body]]` is the concatenated `.ql-chapter` sections. **Paginated mode:** wrap every item; `#content` gets class `hc-continuation` on every item except the first visible one, and a core rule `#content.hc-continuation :is(header, .rh) { display: none }` hides template chrome after the first page. Add `hc-paginated` to `html` and a core rule `html.hc-paginated :has(#bodyContainer):not(#content):not(body):not(html) { border: 0 !important; box-shadow: none !important; background: none !important; padding-inline: 0 !important; margin: 0 !important; max-width: none !important; width: auto !important }` so wrapper boxes do not fragment across columns. Corpus-driven additions to the same step: (a) 10 of 188 templates have no `<header>`, so continuation items are rendered with the `title`, `byline`, `date_*`, `datetime_*`, `feed_link*` and `external_link*` macros set to empty strings, in addition to the CSS hide rule; (b) 15 templates carry `#nnwFooter`, which is hidden on every item except the last visible one (`#content.hc-continuation #nnwFooter, #content.hc-not-last #nnwFooter { display: none }`); (c) the wrapper-neutralizing rule also sets `overflow: visible !important`, because 113 skins put `overflow: hidden` on `.t` `[U]`. Both original rules and these additions are `[U]`: verify visually with Fimfiction, Dark Academia, System, Illuminated Codex (fixed `html::before`), Hung Dates (fixed `.t422::before`) and one of the 10 headerless skins (for example Broadsheet) in paginated mode, and confirm `:has()` on the macOS 13 WebKit floor (U3). Fallback if either fails: paginated mode renders the built-in default template and applies the skin CSS and tokens only; scroll mode keeps the skin template. Record the outcome in the PR.
2. Keep `#content` (reader layout: `max-width: var(--reader-max-width)`, padding) outside the skin wrapper so existing selectors and margins keep working.
3. `html` background stays `background-color: var(--nnw-bg) !important` from the active token set, and paginated column geometry stays `!important` (V16), so skins cannot break columns. `paginatedColumnCSS` ends with `* { max-width: 100% !important; ... }`, which overrides skin `max-width` on every element in paginated mode (for example Fimfiction `.t { max-width: 46em }`): acceptable, record it in the skin authoring notes.
4. Theme swap is `.readerStructuralSettingsChanged` in v1 (full reload with position restore). A live `<style>` swap is deferred (V7, U4).

### 8.3 `readerCSS` changes (inside Phase 4b)

1. **Inline-style cleanup first** (D10), in `extractedChapterBody`: remove only `color`, `background`, `background-color`, `font-family` declarations from `style=`; keep `white-space`, `visibility`, `font-size`, `text-align`. Tests: `style="color:red;white-space:pre"` becomes `style="white-space:pre"`; malformed and empty `style`; uppercase property names.
2. **Demote the reset** (D12). Replace the final `*` rule with:
   ```css
   :where(#bodyContainer *) { font-family: inherit; color: inherit; background-color: transparent }
   ```
   Zero specificity and no `!important`, so skin rules win by order. Presentational hints (`<font color>`, `bgcolor`) have specificity 0 and sit earlier in the cascade, so this rule still neutralizes them `[U: confirm in WKWebView]`. Keep `img, svg { color: unset !important }`.
3. **Free skin typography.** Remove `!important` from `body { font-family; color }`, `h1..h6 { font-family }` and `code, pre { font-family }`. Move them into the override block (8.4), emitted only when the user set the matching override; otherwise the skin decides. The base `body` rule keeps a non-important default so a skinless fallback still renders.
4. **Intended visible change:** because the `*` reset no longer beats it, `a { color: var(--reader-link) }` (and the skin's link color) now takes effect (V16). The three bundled Original, Quiet and Paper skins set `--nnw-link` from today's seed link colors, so the change is deliberate and documented in the PR.
5. **Acceptance:** golden test of the new default CSS (not byte-identical to today, by design); toggle-off preface HTML byte-identical to previous output; manual visual comparison of Original, Quiet, Paper against today's build on one prose book and one Wikisource-style book.

### 8.4 Phase 4c: overrides

Global `ReaderOverrides`, all optional (nil means the skin decides): `paragraphIndent` (em), `paragraphSpacing` (em), `justify`, `hyphenate`, existing font size, line height, max width and padding, color overrides, and **four font roles**: `bodyFont` (serif), `sansFont`, `headingFont`, `monospaceFont`. Define all four fields now so adding downloadable fonts later (D11, deferred) is not a stored-data migration. Nectar models two roles (`serifFontFamilyName`, `sansFontFamilyName`, the latter exposed to skins as `--nnw-font-chrome`); Honeycrisp extends that.

Emission (adapt `ArticleThemeOverrides.cssOverrideBlock`, `Theming/ArticleThemeOverrides.swift` l.241-434):

- `:root` variables with `!important` for `--nnw-bg`, `--nnw-ink`, `--nnw-link`, `--nnw-font-chrome`; light values plus the dark `@media` block.
- `body, #bodyContainer` rules for font family (body role), size, line height, color, background, each with `!important` and each only when set.
- `h1..h6` (heading role), `code, pre` (monospace role) rules, `!important`, only when set.
- `#bodyContainer p, li, blockquote, dd` for paragraph spacing, indent, alignment, hyphenation, with `!important`. Justify skips elements with `align=`, a center class or inline `text-align`, so centered dividers and verse stay put.
- When the user sets a max-width override, also emit `body { max-width: none !important }`: 88 corpus skins cap `body` at about 44em in scroll mode, which would otherwise silently limit the user's setting. Paginated mode already forces `max-width`/`margin` on the body with `!important` (`paginatedColumnCSS`, `bodyWidthCSS`), so skin body widths are ignored there.
- Prose-link override excludes `#ao3Preface a`.
- Clamp indent and spacing to 0 to 3 em in `ReaderCSSSanitizer`; fonts must come from the allowed set (`ReaderCSSSanitizer.fontFamily`); colors must be `#` hex.
- Migration: `removeParagraphIndents` becomes `paragraphIndent = 0` once. Seed overrides from the current theme's values so nothing visibly changes on upgrade. Per-theme typography fields on `Theme` (V20) migrate into the global overrides from the theme that is active at upgrade time.

Tests: emission golden strings, clamps, role fields round-trip, migration.

### 8.5 Phase 4d: replacing `Theme`

- Remove `Theme`, `ThemeColorSet` seeds and the per-theme font and margin fields and their copy sites: `SettingsWindowController` l.1515-1520 and l.1542-1547, `SettingsManager` l.67-250 and l.716-725 `[V per earlier read]`. Re-read each site before editing.
- `ThemePopoverViewController` lists skins instead of `SettingsManager.shared.themes` (l.19).
- Bundled skins (D13): Original, Quiet, Paper as Honeycrisp skins built from the seed values in V20 with minimal templates (`<div id="bodyContainer" class="articleBody">[[body]]</div>`, no header, so existing books look the same), and the Fimfiction variant. Selection persists as the skin id. Migration maps the old theme id to the matching bundled skin by name.
- Keep user-created themes: convert each to a user skin with only `:root` tokens and a font stack, then delete the old storage after a successful conversion.
- `ReaderContrast` and native chrome read the token colors (D7). No probe.

### 8.6 Gallery

No new page. `nectar/gallery/build.py` already publishes `.nnwtheme.zip` files (it reads `Themes/` and `gallery-themes/`); Honeycrisp consumes them through Import. Promote the optional `HoneycrispCompatible` flag to Phase 4a: if present in `Info.plist` it is shown in the picker; if absent the skin still loads and is shown normally (template support makes most gallery skins render fully). A URL scheme and an "Open in Honeycrisp" link stay deferred.

## 9. Deferred (not in this plan)

URL scheme and deep link, remote theme download, Google Font download and cache (proposed Phase 5, decision 14 in section 12: it affects 180 of 188 corpus skins; needs the network entitlement check and `document.fonts.ready` gating for pagination), live skin swap, ficlab flat-tag splitting, cover in the synthesized preface, series navigation and `nectar-series:` links, Book Info (roadmap W12), HTML/TXT/MOBI/AZW3 formats, color probe, drop-cap and chapter-divider JS, mastheads, an author-formatting allowlist, `#nnwFooter`, per-skin overrides.

## 10. Order, size, dependencies

| Phase | Size | Depends on | Risk |
|---|---|---|---|
| 0a Foundations | S | none | Low |
| 0b Layout 2 | M | 0a | Medium (stored user data; own commit) |
| 1 Preface model, extractors, renderer | M | 0a | Medium (parsing variety) |
| 2 Wiring, cut mechanism, setting | M | 0b, 1 | High (navigation, progress, scroll page info) |
| 3 Source profiles | S | 0a | Low |
| 4a Loader, validators, template, import | M | 0a | Medium (security surface) |
| 4b Composition and reset | M | 2, 4a | High (cascade, paginated template) |
| 4c Overrides | S | 4b | Low |
| 4d `Theme` replacement | M | 4a to 4c | Medium (migration) |

One commit per phase. 4a to 4d are separate commits.

## 11. Docs updated in the same changes

- `README.md`, `INDEX.md`: new files, the Settings change, the Skins folder.
- `ARCHITECTURE.md`: new pipeline section; rewrite 5a for layout 2 and the legacy fallback; correct "strips publisher styling" (inline styles survive until 4b step 1); document the cut mechanism and the `:where` reset.
- `CLAUDE.md`: non-goal wording "publisher CSS" becomes "publisher CSS from the book; user-installed skins, reader overrides and Honeycrisp-authored preface styling are allowed". Fix the doc-drift note (the Reading toggles live in the General pane).
- `docs/roadmap-unified.md`: close D12 (approach B), update D13, W2.6, W3.3 and W14.
- `docs/compatibility-corpus.md`: record observations per generator (structure, signals), not the files.
- New `docs/skins.md`: the skin contract (files, tokens, `--nnw-bg` as canvas, macro list, forbidden template content, size caps, paginated-mode behavior, `max-width` override note, `[[font-size]]` handling).

## 12. Risks and open items

1. **Hidden placeholders.** Scroll page counts and `honeycrispPageInfo` (V9) are the likely regression point. Test with a native AO3 fixture in both modes on a Mac.
2. **Paginated template rendering** (8.2): the `hc-continuation` and `:has()` neutralization rules are unverified. Closed by the visual check listed there; fallback is defined.
3. **Reset demotion** (8.3): confirm in WKWebView that `:where(#bodyContainer *)` still neutralizes `<font color>` and `bgcolor`.
4. **Link color change** (V16, 8.3): confirm today's rendering before and after.
5. **WKWebView-hosted XCTest** (U6): if unavailable, the offset guarantee rests on Swift-side tests and manual checks.
6. **Multi-chapter native AO3 and series** (U2): needs a second native sample; fail closed on anything unexpected.
7. **CSS feature floor** (U3): `:has()` (Safari 15.4), `color-mix` (16.2), `:where` (14) on macOS 13.0; this plan avoids nesting, `@scope` and `@layer`. Confirm with `CSS.supports` on a 13.0 machine.
8. **Setter notifications** (U4): read the `SettingsManager` setters (l.755-770) before adding layout-affecting overrides.
9. **`tocSidebar(_:didSelectEntry:)`** (V19): read l.1670 before Phase 2.
10. **FicHub XHTML parse** (U9): test `introduction.xhtml` parses with `XMLDocument`.
11. **Maintainer sign-off needed before coding:** D9 (layout 2), D3 (retiring "Format for AO3"), D6 (template renderer), the `CLAUDE.md` non-goal wording, and the Honeycrisp license check (section 0).
12. **Entitlements** (V17): not needed until the deferred network work; verify with `codesign -d --entitlements :-` on a release build then.
13. **Tokenless skins** (8 of 188): the one-shot `skinCanvasColor` sample in 8.1 is the recommended default; the alternative is rejecting tokenless skins. Needs maintainer approval because it adds a small page-to-native message.
14. **Web fonts** (180 of 188 skins `@import` Google Fonts). With D11 they load with their fallback stacks only (fallback quality not audited), so most of the gallery will not look as designed. Recommended: add Phase 5 after Phase 4: a Settings toggle "Download fonts for skins" (default off); on, fetch only the families named in a skin's leading `@import` from `fonts.googleapis.com` and `fonts.gstatic.com` over HTTPS, cache in `Application Support/Honeycrisp/Fonts/`, and inject as inline base64 `@font-face` rules (the reader can only read files under the book folder, and Hyperlegible and NewsFax already embed fonts as `data:` URLs). Needs the `com.apple.security.network.client` entitlement check (V17) and `document.fonts.ready` gating before pagination. Phase 4 records each skin's font families (`ReaderSkin.fontImports`) and shows "uses web fonts" in the picker so Phase 5 is additive. Needs maintainer approval because it is the first network code.

15. **Corpus-check amendments** (8.1, 8.2): tokenizing `url(` and `@import`, comment stripping, merged `:root` rules, blanked continuation macros, `#nnwFooter` and `overflow` handling. All closed by tests and the visual check listed in those sections.

## 13. Sign-offs (recorded)

Approved by the maintainer: D9 layout 2 (Phase 0b, own commit); D3 retiring "Format for AO3"; D6 minimal template renderer; `CLAUDE.md` non-goal rewording to "publisher CSS from the book; user-installed skins, reader overrides and Honeycrisp-authored preface styling are allowed"; the Nectar port and license handling, with the Honeycrisp license file still to be read before the first port commit. Also approved: the calls listed as overridable (tokenless skins import with default colors, `--nnw-bg` as page canvas with the Fimfiction `--fx-box` edit, four bundled skins, link color change, work chapter headings kept). Items 13 and 14 above (tokenless `skinCanvasColor` sample, Phase 5 fonts) remain recommendations: item 13 is in scope for 4a, item 14 stays deferred.

## Appendix A: fixture skeletons (synthetic, placeholder text only)

Native AO3, four spine files matching the real shapes in 2.2:

```
000: <body><div id="preface"><h2 class="toc-heading">Preface</h2>
       <p class="message"><b>Fixture Title</b><br/>Posted originally on the <a href="https://archiveofourown.org/">Archive of Our Own</a> at <a href="https://archiveofourown.org/works/1">https://archiveofourown.org/works/1</a>.</p>
       <div><dl class="tags"><dt>Rating:</dt><dd><a href="https://archiveofourown.org/tags/General%20Audiences">General Audiences</a></dd>
       <dt>Language:</dt><dd>English</dd><dt>Stats:</dt><dd>Published: 2020-01-02 Words: 10 Chapters: 1/1</dd></dl></div></div></body>
001: <body><div id="preface"><div><h1>Fixture Title</h1><div class="byline">by <a rel="author" href="https://archiveofourown.org/users/A/pseuds/A">Fixture Author</a></div>
       <p>Summary</p><blockquote class="userstuff"><p>Fixture summary.</p></blockquote>
       <p>Notes</p><blockquote class="userstuff"><p>Fixture notes.</p></blockquote></div></div><div id="chapters"><div></div></div></body>
002: <body><div id="chapters"><h2 class="toc-heading">Fixture Title</h2><div><p>Text.</p><p> </p><p>More text.</p></div></div>
       <div id="afterword"><div></div></div></body>
003: <body><div id="afterword"><h2 class="toc-heading">Afterword</h2><p class="message">Please comment.</p></div></body>
```

OPF: `dc:title`, `dc:creator`, `dc:publisher` "Archive of Our Own", `dc:subject` Fanworks plus tags, `dc:description` escaped `&lt;p&gt;...&lt;/p&gt;`. NCX: Preface to 000, title to 002, Afterword to 003 (none for 001). Expected roles: `[primaryPreface, cut, chapter, backMatter]`.

FicHub: two front items (`introduction` with `<p><b>By: Fixture Author</b></p>`, a summary paragraph, `Status:`, `Published:`, `Words:`, `Original source:`, "Exported with the assistance of FicHub.net"; and `nav` with `<nav epub:type="toc">`). FFN variant adds one stats paragraph with a hyphenated character name. FicLab: five front items with body classes `fl-cover`, `fl-title`, `fl-copyright`, `fl-toc`, `fl-summary` and an OPF `ficlab:` identifier. WebToEpub: one `Information` item with `<dl class="work meta group">`.

Skin fixtures (generated in temp directories at test time): a minimal valid bundle; one with no tokens and a dark block (tokenless); one with light tokens and no dark block (single-scheme); one with `--nnw-bg: red`; one with a template containing `<script>` (stripped, template kept); one with `<iframe>` (rejected); one with `<img src="[[avatar_src]]">`; one with a literal `https:` `<a href>`; one with `[[title]]` inside an HTML comment; one with `@import url('https://fonts.googleapis.com/css2?family=X:wght@400;600&display=swap');` followed by `:root` tokens; one with two top-level `:root` rules; one with a `prefers-color-scheme: light` block; one with `url(%23n)` inside a quoted data URI (accepted); one with `[[text_size_class]]` inside a CSS comment; one stylesheet with `url(#frag)` (accepted) and one with `url(https://x)` (rejected); one with `body { max-width: 44em }` (accepted) and one with `body { height: 100% }` (rejected); one with `[[font-size]]` outside `@supports`; one with an NFD folder name; low-contrast pairs at 2.26 (warns) and 1.2 (rejects); a zip with a `../` entry, one with a symlink entry, one with a wrapper folder.

## Appendix B: commands

```
xcodegen generate
./test.sh
swiftlint   # only on touched files; CI does not run it
```


[RESOLVED: all five sign-offs and the overridable calls are approved; see section 13. Kept below for the rationale.]

Five items needed your sign-off before coding. I made calls on a few other things you may want to override.

## Sign-offs required

**1. Layout 2 for saved positions (D9).**
- **What it is:** Scroll mode saves its position as one character count over the whole book, always stored as spine item 0. The preface toggle and the removal of stray `<style>` text change the length of earlier items, so that count would drift. The fix saves the chapter plus an offset inside it, and bumps `EPUBAnchor.currentLayout` to 2.
- **The cost:** Existing entries are still restored by the old method once. That is exact unless the book had `<style>` text or you turn the preface on, and in those cases it falls back to the progress percentage.
- **The alternative:** Leave positions alone and accept the drift.
- **Recommendation:** Approve. The same JS can store a scroll fraction as a character offset, which restores to the end of the book. That bug exists today, so fixing it is worth doing now. It ships as its own commit (Phase 0b) before any preface work.

**2. Retiring "Format for AO3" (D3).**
- **What it is:** The old setting deletes every `h2.toc-heading` and keys on a per-book `calibre2` class. In the sample it deletes the only chapter title. The replacement is a toggle that builds the preface from metadata.
- **The cost:** People who use the old setting get it migrated to the new toggle, and their saved positions can shift once.
- **Recommendation:** Approve. The old behavior is a bug, and keeping both settings would confuse users.

**3. The minimal template renderer (D6).**
- **What it is:** Honeycrisp would honor `template.html` through a small substituter with a fixed list of macros, and reject any template containing scripts, iframes or remote URLs.
- **The cost:** More code, and a new security surface around user-installed HTML.
- **The alternative:** Skip templates. Then Fimfiction's box and title block, and most `.tNN`-scoped gallery rules, never match, and the "reuse the gallery" goal fails.
- **Recommendation:** Approve. Eight of the ten bundled templates are under 600 bytes and none has a script, so the surface is small. One piece is unproven. Template chrome in paginated mode relies on `:has()` rules I haven't tested. If they fail, paginated mode uses the default template and keeps the skin's CSS, and scroll mode keeps the skin's template.

**4. `CLAUDE.md` non-goal wording.**
- **What it is:** "Publisher CSS" is a listed non-goal. Skins, overrides and the generated preface styling would technically violate it.
- **Recommendation:** Approve the rewording to "publisher CSS from the book; user-installed skins, reader overrides and Honeycrisp-authored preface styling are allowed". Nothing is lost, because the book's own CSS is still never loaded.

**5. Honeycrisp's license.**
- **What it is:** The plan copies and adapts Nectar code (MIT, from NetNewsWire), and the license file isn't in the upload zip.
- **Recommendation:** Check it before the first port commit. If it's compatible, add the Nectar notice. If not, rewrite the ports instead of copying them.

## Calls I made that you can override

- **Missing color tokens (D7).** Skins without `--nnw-bg`, `--nnw-ink` or `--nnw-link` import with Honeycrisp's defaults instead of being rejected. That keeps all ten gallery bundles usable. A token that is present but malformed is rejected. The stricter option rejects `System` and `Reversi`, and I don't recommend it.
- **`--nnw-bg` means page color.** This matches Nectar's documentation. Fimfiction needs a small edit, and its box color moves to a new `--fx-box`. A user background override recolors the page but not `--fx-box`.
- **Bundled skins (D13).** Only Original, Quiet, Paper and the Fimfiction variant ship in the app. Other gallery skins come in through Import. Bundling all ten adds roughly 170 KB of CSS and templates plus a notice for each. I don't see a reason to do it.
- **Link colors will change.** The current `*` reset likely forces links to body text color, and removing it lets the skin's link color apply. I read this from the cascade and haven't confirmed it in a running build. I think it's the right outcome, but it is a visible change for every user, so it should go in the PR description.
- **Chapter headings.** The plan keeps the work's chapter headings, which the old setting deleted. If you want an option to hide Calibre's headings, say so now, because it affects the migration.

## Not decisions, but gating

A few unproven items could change the implementation without needing your input. They are the `:where` reset against `<font color>`, the paginated template rules, and the `tocSidebar(_:didSelectEntry:)` call path. Each has a closing step in section 12 of the plan. I'd close the first two with a manual check on a Mac early in Phase 4b.

If you approve 1 through 4 as recommended and the license check passes, Phase 0a can start immediately, since it changes no behavior beyond stripping body `<style>` and `<script>`.
