# Honeycrisp final plan: content pipeline (M6) now, flow engine (M4a onward) next

Audience: the AI engineer implementing this. This is the only planning document you will receive. Mode: Implement for docs pass 0 and M6 passes 1 to 8
(sections 4 and 5); sections 6 to 9 are direction for later milestones and each of those needs its own handoff plan before code starts.

Roadmap: M6 (now), then M4a, M5, M7 (R20, R21, R22; R5, R9, R10, R11). Contracts: C1, C2, C3, C4, C5, C6. Base: `main` at 91c0dfd
(`.git-meta/head.txt`). Nothing here was built or run; there is no macOS toolchain in the planning environment. The owner runs
`xcodegen generate`, `./test.sh`, `swiftlint`. The owner instructed that SwiftSoup is assumed to work; that is Unverified until the first green `./test.sh` after M6 pass 1.

Tags: Verified means read in the zip (file and symbol) or in a local sample's structure. Unverified means inferred or needs a run on macOS.

## 0. Read this first

1. Read `CLAUDE.md` in the zip, then `INDEX.md`, `docs/FRAMEWORK.md` (C1 to C6) and `docs/ROADMAP.md` (R20 to R22, M4a, M6). The zip's rules win over any default. They include: hide
   elements, never delete (R21); one concern per pass; stacked diffs built with `bash scripts/make-diff.sh`; never edit or diff `Honeycrisp.xcodeproj`; never claim a build or test passed
   unless it ran; no emojis, no em-dashes; no new dependency, persisted-format change or contract change without asking; tests use synthetic fixtures only; no book titles or authors in docs or reports (structure only).
2. Working tree at the base (`.git-meta/status.txt`): modified `ARCHITECTURE.md`, `CLAUDE.md`, `INDEX.md`, `docs/FRAMEWORK.md`, `docs/ROADMAP.md`, `docs/compatibility-corpus.md` (the R20 to R22 docs patch);
   untracked `docs/m4-pass7-plan.md` (a handoff file: do not commit) and `swiftlint.txt` (local lint output).
3. Diffs. Docs pass 0 is a diff supplied with this plan (`pass0-docs-alignment.diff`, relative to the zip; `git apply --check` passed against the zip). Apply it first. Pass 1 is then
   relative to the pass 0 result, and so on; after every pass present the incremental `passN-slug.diff` and `combined-through-passN.diff` (relative to the zip), check both with `git apply --check`, and end with the pass report
   (files changed, tests added, untested areas, commands for the owner, next pass).
4. Terms. "Merged document": the 2.2.1 default path, `EPUBParser.buildScrollHTML`, one HTML string for the whole book built with regexes. "Flow surface": the new default (`FlowSurface`, M4a): one document with a
   `section` per chapter served by the scheme handler. "Chapter host": `ChapterHostSurface`, iframe per chapter, windowed, frozen at bug fixes behind `HONEYCRISP_CHAPTER_HOST=1`. "Pipeline": `ChapterPipeline`, the new L2 code built in M6.
5. Process (owner decision): each pass is a PR from a short-lived branch (for example `pass-1-decoder`) merged when the Tests workflow is green (`tests.yml`: `xcodebuild test` on `macos-26`, Xcode 26.3, on push to `main` and on PRs; it runs no SwiftLint). The branch
   `chapter-engine` (created by the owner at 91c0dfd) is a snapshot only: do not develop on it. No tag, release branch or worktree is needed.

## 1. Scope, order and what is already decided

Order (ROADMAP section 4): docs pass 0, then M6 passes 1 to 8, then M4a, then M5, then M7.2 to M7.4; M7.1 (HTML, Markdown, TXT adapters) may start after M6 in parallel with M4a and M5. M4 (windowed chapter host) stays paused.

Why this order, in one paragraph: 2.2.1 uses one merged document built by regexes. The M3 spike (scheme handler, `ServedChapter`, `ChapterHostCSS`, content JavaScript off, client-world scripts) and M4 (windowed iframe host)
reached no user: every path runs only under `HONEYCRISP_CHAPTER_HOST=1`, and flag mode saves no position and has no search, speech, bookmarks or links. The adopt decision rested on synthetic fixtures. The owner's largest real book (below) is usable
in the merged document. So the default becomes a flow surface (one document, section per chapter, positions per chapter) fed by one SwiftSoup pipeline, and the chapter host stays as a frozen alternative behind the same seam. The pipeline comes first because
both surfaces and every new format need it, and because it fixes defects found in the samples.

Decided (do not re-ask): SwiftSoup 2.14.3 becomes an app dependency (R5). `EPUBAnchor.currentLayout` goes 1 to 2 once, in M6 pass 8, with the fraction fallback. The paragraph-indent transform is not ported (D1 below). No throughput budget for M6 (D5 below).
Chapter host code stays in `main`. The env flag stays the only engine switch.

Open decisions are in section 8. None blocks docs pass 0 or M6.

## 2. Evidence the design rests on (structure only; no book files exist in the repo)

Scale. The owner's largest local EPUB (title omitted): 9 MB zip, 307 chapters, 26.0 MB XHTML, 23.07M characters, 4.07M words, median chapter 87 KB, largest 150 KB, 106,754 `<p>`, 794 `<hr>`, 395 `<em>`, no images or scripts, calibre 6.23.0 output.
The owner reports 2.2.1 opens it, shows about 65 MB (process not identified), "does not feel that bad", with slow style changes and janky fast scrolling (what one 23M-character DOM would cause). Scaling the 2,000-page fixture linearly predicts about 870 MB of WebContent memory (Unverified; the two figures probably measure different processes).
The 2,000-page baseline (ROADMAP): build 469 ms (the regex pipeline is about 58% of open), load and layout 332 ms, open about 820 ms, WebContent 124 MB.

Samples (local only; static inspection recorded in `docs/compatibility-corpus.md`):

| Sample class | Finding | Consequence |
|---|---|---|
| AO3 EPUB, HTML, AZW3 | `calibreN` classes; `.toc-heading { display: none }` (EPUB and HTML); filler `<p> </p>` between paragraphs; AO3 HTML is one file with `#preface`, `#chapters`, `#afterword` (markup inside `#chapters` not inspected) | Dropping CSS un-hides the heading: hide, never delete. HTML needs a chapter split. |
| fichub EPUBs | no classes; XML declaration plus `<!DOCTYPE html>`; `<p/>` (16 in the FFN file) | In `text/html`, `<p/>` is an open tag: parse EPUB XHTML as XML, serialize as HTML. |
| FicLab EPUBs | indent, justify, typography only in CSS; `.underline`, `.strikeout`, `.align-center`, `.monospace` in each chapter's head; `#landmarks { display: none }` | Harvest a small whitelist (M4a, R21). |
| Fimfiction EPUB, HTML, TXT | EPUB baseline (94 `<em>/<i>`); HTML has `<header>`, `<nav>`, 2 `<article>`, a `<details>` summary, one remote cover `<img>`, 11 `<hr>`; TXT is not Markdown (UTF-8, CRLF, `> ` header block, `> N. Title` chapter lines) | `<article>` likely chapter boundary; remote-image policy; TXT adapter. |
| wikisource, gutenberg2 EPUBs | 179 and 749 self-closing non-void tags; wikisource 429 inline style attributes; gutenberg2 770 occurrences of `sidenote` | Strongest proof that XML parsing is mandatory; gutenberg2 is the case that keeps the chapter host valuable. |
| AO3 MOBI and AZW3 (proxy unpack, not libmobi) | AZW3 (KF8) unpacks to split part files with the same `calibreN` classes; MOBI 6 unpacks to one `book.html` with `<font>`, `filepos` anchors, `<a id/>` and 8 `mbp:pagebreak` markers; encryption field 0 in all | AZW3 converts like an EPUB; MOBI splits on `mbp:pagebreak`; non-zero encryption must be reported as DRM. |

Generator CSS carries a little meaning (hiding and a handful of inline semantics); italics and bold are real `<em>`/`<strong>` in every fanfiction sample, so they survive a CSS drop. Geometry belongs to the user layer (C4).

## 3. Target design (what M6 builds the base of, and M4a completes)

Layers (FRAMEWORK section 2): L0 Format adapters (EPUB now; HTML, TXT, Markdown, MOBI/AZW3 in M7) produce an L1 `Publication`; L2 Content is the pipeline (SwiftSoup: decode, parse, sanitize, transform, serialize, text extraction), pure Swift, no AppKit, no WebKit, no `UserDefaults`;
L3 Surface is the `FlowingSurface` protocol with `FlowSurface` (new default) and `ChapterHostSurface` (exists); L4 State is `Locator`, history, bookmarks (exists, M1). PDF and CBZ use `PagedSurface` and are not touched.

Flow document (M4a): `<body class="hc-flow"><section class="hc-chapter" data-resource="N" id="hc-rN">...</section>...`, ids namespaced `hc-r{N}-{id}`, internal links rewritten through a path-to-resource table, resource URLs resolved per chapter, served by `EPUBResourceSchemeHandler`
(`honeycrisp-epub://`, the document as an `appResources` entry), content JavaScript off (`allowsContentJavaScript = false`; today `ReaderViewController` line 187 is `true`), reader scripts as client-world `WKUserScript`s, CSP through `responseHeaders` if enforcement is verified.
Positions are `(resource, offset)` with the text-node walk rooted at one section.

Hazard to handle in M4a (Verified: `EPUBResourceSchemeHandler.mimeTypes`, lines 82 to 84): `html` and `htm` are served as `application/xhtml+xml`, and `appResources` takes the MIME type from the key's extension. A flow document served that way is parsed as XML, and the pipeline's HTML serialization (`<br>`, named entities) is not well-formed XML.
M4a must serve the flow document as `text/html` (a MIME override for app resources), with a test that a document containing `<br>` and `&nbsp;` loads.

Normalization rules and who delivers them:

| Rule | Content | Delivered by |
|---|---|---|
| N1 | Decode (BOM, XML declaration, `<meta charset>`, UTF-8, windows-1252); parse EPUB XHTML as XML, other markup as HTML; serialize HTML syntax, pretty print off, `<p></p>` never `<p/>` | M6 passes 1, 2 |
| N2 | Remove `script`, `iframe`, `object`, `embed`, `base`, refresh `meta`, `on*` and `srcdoc` attributes, `javascript:` URLs | M6 pass 2 |
| N4 (URL part) | Resolve `src`, `href`, `xlink:href` from the chapter's own directory, contained in the book root (as `file:` URLs in M6) | M6 pass 4; M4a retargets to the app scheme and adds `poster`, `srcset`, `data`, `style url()` |
| N7 | AO3 formatting, spacer tagging, preface heading as DOM rules; headings hidden, not deleted; indent stripping dropped | M6 passes 3, 5 |
| N3 | Harvest publisher CSS whitelist (`display:none` as `hidden`, italic, bold, underline, line-through, center or right alignment, monospace) for simple selectors; geometry ignored; cascade by source order | M4a (R21) |
| N5 | Namespace ids, rewrite internal links | M4a |
| N6 | HTML5 blocks from single-file sources (`<details>` open; `<nav>` hidden after splitting) | M4a or M7.1 |
| N4 (remote images) | External `http(s)` images not loaded by default (`data-hc-remote-src` kept); `loading="lazy"` on `<img>` (behavior with the custom scheme Unverified) | M4a, decision X7 |

Large books (a measured ladder, not a guess): (1) parse chapters concurrently (M6 pass 7); (2) perceived open: chunked delivery from the scheme handler, only if measured (`didReceive` repeated before `didFinish` is Unverified); (3) style-change latency: `.readerCosmeticSettingsChanged` relayouts the whole DOM,
so measure first, and consider `content-visibility: auto` with `contain-intrinsic-size: auto` only for large books (macOS 13 and 14 availability Unverified; estimated heights bring back scroll shifts); (4) last resort: select the chapter host above a measured size (X3).

## 4. Docs pass 0 (apply the supplied diff; no code)

`pass0-docs-alignment.diff` edits two repo files so the docs match this plan before any code lands:
- `INDEX.md`: header base commit 3f033bc to 91c0dfd.
- `docs/ROADMAP.md`: M6 text (decode order gains the XML declaration step; indent transform not ported; concurrency stays synchronous until M4a; no hard time budget; layout bumped once by M6); M4a text (transforms ported by M6; a further layout change, needs owner approval before the position pass; flow document served as `text/html`); M5 text (the delete step is conditional on owner confirmation and `rewriteResourceURLs` is already gone).
`docs/FRAMEWORK.md` C2 already states that the walk counts hidden text; no FRAMEWORK edit is needed now.
Commands: `git apply --check pass0-docs-alignment.diff` against the zip tree, then apply. Done when: the two files match the diff and nothing else changed. Risk: none (docs only).

## 5. M6: content pipeline on SwiftSoup (implementable now)

### 5.1 Goal and non-goals

Goal:
1. One L2 pipeline, `ChapterPipeline`, built on SwiftSoup, that turns chapter bytes into the served body markup and into the
   text that search and speech use. It replaces every regex that touches HTML structure in `EPUBParser`.
2. Active content is removed with a real parser (C6): no `<script>`, `iframe`, `object`, `embed`, `base`, refresh `meta`, `on*`
   attributes or `javascript:` URLs in chapter bodies.
3. Text extraction equals the page script's text-node walk for the same served body (C2), proven in a real `WKWebView`.
4. Elements are hidden, never deleted (R21). No transform deletes text. The paragraph-indent transform is not ported (D1, resolved): `removeParagraphIndents` becomes a no-op in the pipeline for now.
5. `EPUBAnchor.currentLayout` bumped once by M6 (1 to 2), with the fraction fallback tested. M4a changes the scroll-mode offset base later and has its own layout decision (X1 in section 8); this plan does not cover it.
6. Chapter parsing runs concurrently and its throughput is measured on a 150 KB chapter and on 300 chapters. There is no hard budget (D5, resolved); the owner judges speed by feel and the numbers are recorded for reference.

Non-goals: the `FlowingSurface` seam, `FlowDocumentBuilder`, per-section offsets, the app-scheme document (all M4a); position
mapping and deleting `buildScrollHTML` (M5, decision X2 in section 8); R21 style harvest (M4a); any change to `ChapterHostSurface` or its frozen M4 code;
OPF, TOC and landmark parsing (L0, stays on `XMLDocument`); moving files out of `EPUBParser.swift` (M5 splits it); new settings.

### 5.2 Facts (code at 91c0dfd)

All Verified unless tagged.

F1. The default render path builds one merged HTML string. `EPUBParser.buildScrollHTML` loops `pkg.spineURLs`, calls
`EPUBParser.extractedChapterBody` per chapter and wraps each in `<section class="ql-chapter" id="chapter-N" data-chapter-index="N">`
with `\n` before and after. `EPUBParser.buildPageHTML` does the same for one index. Callers: `ReaderViewController.renderScrollContent`
and `ReaderViewController.loadSpineItem`. Both run synchronously on the main thread and write `_ql_reader.html`.

F2. `extractedChapterBody` reads bytes with `Data(contentsOf:)`, decodes as UTF-8 else ISO Latin-1 (no BOM, no meta charset), then
runs: `extractBody` (find `<body`, `</body>` by string search), `applyFirstChapterFormatting` (flag `formatFirstChapter`),
`stripLeadingIndentWhitespace` (flag `removeParagraphIndents`), `markSpacerParagraphs` (flag `collapseSpacerParagraphs`),
`stripPrefaceHeading` (spine index 0 only), `rewriteResourceURLs`. All five helpers are regex or string scanning.

F3. No active-content removal exists in the default path. `ReaderViewController.loadView` sets `allowsContentJavaScript = true` (INDEX,
CLAUDE.md invariant). Body scripts survive. M6 removes them from the markup; turning author JavaScript off for the default
path is M4a.

F4. Deletions that change offsets today: `applyFirstChapterFormatting` removes `h2.toc-heading` elements; `stripPrefaceHeading` removes
headings that read "Preface"/"preface"; `stripLeadingIndentWhitespace` removes leading space and tab runs after start tags of
`p|div|li|h1-h6|blockquote|td|th`. This contradicts R21 (hide, never delete) for the first two.

F5. `rewriteResourceURLs` resolves relative `src="..."` and `href="..."` against `pkg.rootFolder`, not against the chapter's own directory.
It matches only double-quoted attributes, skips values with prefixes `http`, `file:`, `data:`, `#`, `mailto:`, `javascript:` (so a relative
path beginning with "http" is skipped by mistake), and its pattern also matches inside `xlink:href="..."`. These are the confirmed bugs that
`WebKitOffsetParityTests.testSyntheticFixtureCapturesKnownResourceAndLinkBugs` pins as expected failures.

F6. Search and speech text: `EPUBParser.searchResults` and `EPUBParser.speechText` call `extractedChapterBody` with
`formatFirstChapter: false, removeParagraphIndents: false`, then `searchableText`. The rendered page uses the user's real settings.
So search offsets drift from rendered offsets whenever either toggle is on (existing bug, closed by pass 6).

F7. `searchableText` strips `<script>` and `<style>` text, but the page script's `TreeWalker(document.body, SHOW_TEXT)` counts text inside
them (`EPUBParser.readerJS`: `honeycrispCurrentCharacterOffset`). It also decodes `&amp;` before `&lt;`, so `&amp;lt;` becomes `<`
(pinned by `SwiftSoupSpikeTests.testRegexEntityDecodingDoubleDecodesAmpersandEntities`, an expected failure). Both are offset drift.

F8. Offset definition: UTF-16 length of text nodes before the position, `TreeWalker(SHOW_TEXT)` over `document.body` (whole merged document in the default
path, `PaginationJS` and `readerJS`; per chapter body in the chapter host: `ChapterHostScript.source`). `WebKitOffsetParityTests` (merged
document) is an expected failure because section wrapper whitespace shifts offsets (decision B1, stays until M4a).
`ChapterHostOffsetParityTests` (per chapter, host) is a passing test.

F9. The chapter host serves raw chapter bytes through `EPUBResourceSchemeHandler.transform`, set to `ServedChapter.prepare`
(`ChapterHostSurface.install`). It does not use `extractedChapterBody`. Its offsets are over raw chapter text.

F10. Layout bump plumbing exists. `EPUBAnchor.currentLayout = 1`, `legacyLayout = 1` (`PaginationEngine.swift`).
`Locator.flowRestoreTarget` returns `.offset` only when the saved layout equals `currentLayout`, else `.fraction`. `HistoryManager.savedLocator`
feeds it; `ReaderViewController` reads it at the two restore sites (`savedLocator(for:)?.flowRestoreTarget`, lines 504 and 645 at this base).
`HistoryManager.record` carries the existing entry's `anchorLayout` forward; `updatePosition` writes `currentLayout`. `ReadingBookmark.anchorLayout` is set to `currentLayout` on creation.

F11. Dependencies: `project.yml` lists SwiftSoup `exactVersion: 2.14.3` as a package but only the `HoneycrispTests` target links it. The
Honeycrisp target links ZIPFoundation only. `Package.swift` (tools 5.9) lists ZIPFoundation only. `Package.resolved` lists ZIPFoundation 0.9.20 only.
CI runs on `macos-26` with Xcode 26.3 (`.github/workflows/*.yml`), a Swift 6 toolchain, which SwiftSoup 2.14.3's tools-version 6.0
manifest needs (manifest read per roadmap B2; not re-read here). Both targets declare `SWIFT_VERSION: "5.9"`.

F12. Lint: `.swiftlint.yml` line length 160, trailing commas required; `swiftlint.txt` shows file length (400), function body (50) and
cyclomatic (10) are enforced as warnings. Keep new files under 400 lines and functions under 50.

F13. The regex `String` helper `replacingOccurrences(of:with:)` (closure form, private extension at `EPUBParser.swift` end) is used by
`searchableText` and `rewriteResourceURLs` in `Sources/Parsing`; use elsewhere in `Sources` is Unverified (grep in verify list).

F14. `SpacerParagraphTests` asserts exact serialized strings (`<p class='ql-spacer calibre7'>&#160;</p>`, original quoting and case).
DOM serialization cannot preserve those, so it needs a rewrite in pass 5.

F15. `SyntheticBook` (tests) writes a deterministic EPUB folder of a given page count; `ChapterHostWindowHarness` builds temp books with custom
chapter XHTML; `TestDiagnostics.write(_:lines:)` writes to `build/diagnostics/`. `ReaderBaselineTests.openOnce` already measures
`buildScrollHTML` time (`buildMs`) on the 2,000-page fixture; 2.2.1 total open is about 820 ms and 124 MB (ROADMAP M4a gate).

### 5.3 Layers, contracts, invariants

Layer: L2 (Content). New code is pure Swift, imports Foundation and SwiftSoup only; no AppKit, no WebKit, no `UserDefaults` (FRAMEWORK
section 2). Settings are passed in as values. The settings-reading helper lives in L4/L5 (pass 6).

Contracts:
- C2 (offset parity): the Swift text of a served body equals the JS walk of that body. Gate in every pass that changes L2 output.
- C1/C10 layout: bump once at pass 8.
- C3: EPUB XHTML is parsed as XML, everything else as HTML; one canonical HTML serialization out.
- C4: no new style ownership. `hidden` and `ql-spacer` carry meaning only.
- C6: parser based removal; strings from books never reach JavaScript (unchanged).

Invariants to keep (CLAUDE.md): hide, never delete; one content pipeline shared by scroll and paginated modes (`extractedChapterBody` is
replaced by `ChapterPipeline`, still called from both builders); `EPUBParser.javaScriptStringLiteral` unchanged; `HistoryManager.record`
unchanged; `Honeycrisp.xcodeproj` never edited or diffed; `buildScrollHTML`/`buildPageHTML` signatures unchanged so
`ReaderViewController` render call sites do not change.

### 5.4 Public API (new, `Sources/Content/`)

Decision D6 proposes `Sources/Content/` for new L2 files (FRAMEWORK target home). `project.yml` and `Package.swift` use directory paths, so files
are picked up; run `xcodegen generate` after adding them.

```swift
// ChapterDecoder.swift (pass 1)
enum ChapterDecoder {
    enum Source: Equatable { case bom, xmlDeclaration, metaCharset, utf8, windows1252 }
    struct Decoded: Equatable { let text: String; let source: Source }
    static func decode(_ data: Data) -> Decoded
}

// ChapterMarkup.swift (pass 2)
enum ChapterMarkup {
    enum Syntax: Equatable { case xml, html }
    static func syntax(mediaType: String?, pathExtension: String) -> Syntax
    static func parse(_ source: String, syntax: Syntax) throws -> Document      // SwiftSoup.Document
    static func body(of document: Document) throws -> Element
    static func removeActiveContent(in root: Element) throws
    static func bodyHTML(of body: Element) throws -> String                      // inner HTML, html syntax, prettyPrint off
}

// ChapterText.swift (pass 2)
struct ChapterText: Equatable {
    let string: String              // every text node under body, DOM order, no exclusions
    let hiddenRanges: [NSRange]     // UTF-16 ranges inside an element that carries `hidden`
    static func extract(fromServedBodyHTML html: String) throws -> ChapterText   // parses with the HTML parser, like WebKit
}

// ChapterTransforms.swift (pass 3)
struct ChapterTransformOptions: Equatable {
    var formatAO3 = false
    var markSpacers = false
}
enum ChapterTransforms {
    static func apply(_ options: ChapterTransformOptions, hidePrefaceHeading: Bool, to body: Element) throws
}

// ChapterURLs.swift (pass 4)
enum ChapterURLs {
    static func rewrite(in body: Element, chapterURL: URL, root: URL) throws
}

// ChapterPipeline.swift (pass 4, concurrency in pass 7)
enum ChapterPipeline {
    static func render(chapterAt url: URL, mediaType: String?, resource: Int, root: URL,
                       options: ChapterTransformOptions) throws -> String        // served body markup
    static func text(chapterAt url: URL, mediaType: String?, resource: Int, root: URL,
                     options: ChapterTransformOptions) throws -> ChapterText
    static func renderAll(count: Int, _ body: (Int) throws -> String) throws -> [String]   // pass 7
}
```

Error policy (matches today: a bad chapter never aborts the book): `ChapterMarkup.parse` as XML; if it throws, retry as HTML (D8); if both
throw, `ChapterPipeline.render` returns `""` and the failure is not fatal. File read errors still throw, as `Data(contentsOf:)` does now.
`render` returns the same shape `extractedChapterBody` returns today: inner body markup with URLs rewritten, no `<body>` tag.

### 5.5 Passes

Each pass: tests included, docs in the same pass, lint on touched files. Pass sizes are estimates of changed source lines (tests and docs excluded).
Stacked diffs, one concern each.

#### Pass 1. Link SwiftSoup into the app; byte decoding

Objective: SwiftSoup is an app dependency; chapter bytes decode correctly. No behavior change yet.

Files:
- `project.yml`: add `- package: SwiftSoup` / `product: SwiftSoup` to `targets.Honeycrisp.dependencies`. Keep it on `HoneycrispTests` (the spike test
  imports it; whether the test target needs its own link when the host app links it is Unverified, so keep both). Replace the "SPIKE ... test target only" comment with
  "R5 adopted: app and test targets".
- `Package.swift`: add `.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")` and `.product(name: "SwiftSoup", package: "SwiftSoup")` to the executable target.
  Do not edit `Package.resolved` (its revision SHA must come from a resolve, not from memory); the owner runs `swift package resolve` or lets Xcode write it.
- New `Sources/Content/ChapterDecoder.swift` (about 110 lines).
- `docs/ROADMAP.md`: R5 row: append "Adopted on owner instruction before the spike result was recorded; confirmed by the first green `./test.sh` run". M6 `Status:` line: "in progress (pass 1 of 8)".
- `CLAUDE.md` (zip copy): Targets bullet, replace "SwiftSoup 2.14.3 is a test-target-only spike ... not linked into the app" with the new fact.
- `INDEX.md`: root table and a new `Content (Sources/Content)` source map entry.

`ChapterDecoder.decode` order: (1) BOM: EF BB BF is UTF-8 (strip), FF FE and FE FF are UTF-16 LE and BE (strip); UTF-32 unsupported. (2) Prescan the first 1024 bytes
as ISO Latin-1 text (lossless for ASCII) using `range(of:)` and manual attribute reading, not regex: `<?xml ... encoding="X"?>`, then `<meta charset=X>`, then `<meta http-equiv="Content-Type" content="...charset=X">`.
Map the label with `CFStringConvertIANACharSetNameToEncoding` then `CFStringConvertEncodingToNSStringEncoding`; an unknown label is ignored; a UTF-16 label found by the prescan is ignored (a byte-wise ASCII prescan
cannot see it). (3) Strict UTF-8 (`String(data:encoding:.utf8)` non-nil). (4) `.windowsCP1252`, then `.isoLatin1` if that returns nil (today's fallback).
The `Source` records which step won. The XML declaration step is an addition to the roadmap order (D3).

Tests (`Tests/HoneycrispTests/ChapterDecoderTests.swift`):
- `testUTF8BOMIsStrippedAndReported`: bytes with EF BB BF decode to text without U+FEFF, source `.bom`.
- `testUTF16LittleEndianBOMDecodes`: FF FE plus UTF-16LE of "caf\u{e9}" gives "caf\u{e9}", `.bom`.
- `testXMLDeclarationLatin1Decodes`: declaration `encoding="ISO-8859-1"`, byte E9 gives "\u{e9}", `.xmlDeclaration`.
- `testMetaCharsetWindows1252Decodes`: `<meta charset="windows-1252">`, bytes 93 94 give U+201C U+201D, `.metaCharset`.
- `testHttpEquivContentTypeDecodes`: `content="text/html; charset=iso-8859-1"`.
- `testInvalidUTF8WithNoLabelFallsBackToWindows1252`: bytes 93 94, `.windows1252`.
- `testBOMWinsOverConflictingMeta`, `testUnknownLabelIsIgnoredAndUTF8Used`, `testPlainUTF8ReportsUtf8`, `testMetaBeyondFirstKilobyteIsIgnored`.

Commands: `xcodegen generate`, `./test.sh`, `swiftlint` on `ChapterDecoder.swift`, `ChapterDecoderTests.swift`.
Done when: `./test.sh` green with SwiftSoup linked into both targets on the owner's machine; no existing test changed.
Must not touch: `EPUBParser.swift`, any Reader or Settings file, `Package.resolved`.
Risk: SwiftSoup (tools 6.0) fails to build under the app target's Swift 5.9 mode or sandbox; rollback is reverting the `project.yml` and `Package.swift` hunks (the decoder has no SwiftSoup dependency).

#### Pass 2. Parse, sanitize, serialize, text extraction, parity harness (not yet wired)

Objective: the L2 core exists and is proven against WebKit on its own.

Files: new `Sources/Content/ChapterMarkup.swift` (about 150 lines), `Sources/Content/ChapterText.swift` (about 60); test helper
`Tests/HoneycrispTests/ChapterFixtures.swift`; tests below. `INDEX.md` entries.

`ChapterMarkup`:
- `syntax(mediaType:pathExtension:)`: `.xml` for `application/xhtml+xml` or, when media type is nil, extensions `xhtml` and `xml`; everything else `.html` (C3).
- `parse`: `SwiftSoup.parse(source, "", Parser.xmlParser())` for `.xml`, `SwiftSoup.parse(source)` for `.html`; then
  `document.outputSettings().prettyPrint(pretty: false).syntax(syntax: .html).charset(.utf8)` (exact API names Unverified; the spike
  uses `outputSettings().syntax(syntax:).prettyPrint(pretty:)`). Pretty printing must be off: it inserts whitespace text nodes.
- `body(of:)`: first element named `body` case-insensitively (the spike uses `select("body")`); when none exists (fragment), the document's first element child.
- `removeActiveContent`: remove elements `script, iframe, object, embed, base`, and `meta` whose `http-equiv` is `refresh` (case-insensitive); remove every attribute whose lowercased name begins with `on` or equals `srcdoc`;
  remove `href`, `src`, `xlink:href`, `action`, `formaction`, `poster`, `data` when the value, after dropping leading ASCII whitespace and control characters and lowercasing, starts with `javascript:`.
  Iterate with `body.select("*")`, snapshot to an array before mutating.
- `bodyHTML`: `body.html()` (inner HTML). Empty non-void elements serialize as `<a id="x"></a>` and `<p></p>`, so `<p/>` and `<a id/>` cannot swallow following
  content when WebKit parses the string as HTML. Whether `html()` honors the document's output settings is Unverified.

`ChapterText.extract(fromServedBodyHTML:)`: `SwiftSoup.parseBodyFragment(html)`, then a depth-first walk accumulating `TextNode.getWholeText()` for every text node under the body, with no tag exclusions
(script is already gone, style text counts, as in the JS walk). Record `NSRange`s (UTF-16, `(string as NSString).length`) for text nodes that have an ancestor with the `hidden` attribute. It parses the served string with the
HTML parser, not the XML DOM, so quirks WebKit applies to the same string (newline after `<pre>`, table foster parenting, CRLF) are applied here too. Residual differences found by the parity test are fixed in `ChapterText`, or listed in 5.7 as a known gap before the pass is accepted.

`ChapterFixtures` (named fixtures, all synthetic strings, generated in code): `entities` (`&amp;lt;`, `&#xA0;`, `&#169;`), `supplementary` (U+1F600), `whitespace` (tabs, runs of spaces, LF and CRLF inside text),
`selfClosing` (`<p/>`, `<a id="x"/>`, `<br/>`), `preNewline` (`<pre>\nline</pre>`), `tableWhitespace` (whitespace between `<tr>` elements), `scriptAndStyle` (script and style in body), `nestedParagraphs`, `inlineSVG`, `empty`.
Pass 3 and pass 4 append `transforms` and `urls` sets to the same file.

Tests:
- `ChapterMarkupTests` (pure): `testXHTMLIsParsedAsXMLAndHTMLAsHTML`; `testSelfClosingNonVoidElementsSerializeAsEmptyPairs` (`<a id="x"/>Text` stays outside the anchor, `<p/>` does not wrap the next paragraph);
  `testScriptIframeObjectEmbedBaseAreRemoved`; `testRefreshMetaIsRemovedAndOtherMetaKept`; `testEventHandlerAttributesAreRemovedIncludingMixedCase` (`onClick`, `ONLOAD`); `testJavaScriptURLsAreRemovedWithLeadingWhitespaceAndMixedCase`
  (`href=" JaVaScRiPt:x"`); `testOrdinaryLinksAndAttributesNamedOnlyLikeOnAreKept` (`href="chapter2.xhtml"`, `data-once` is kept: starts with `data-`, not `on`); `testNoPrettyPrintWhitespaceIsAdded`; `testBodylessFragmentUsesRoot`.
- `ChapterTextTests` (pure): `testAmpersandEntitiesDecodeOnce` (`&amp;lt;` becomes the four characters `&lt;`); `testSupplementaryCharacterCountsTwoUTF16Units`; `testWhitespaceIsPreservedExactly`; `testStyleTextInBodyIsCounted`;
  `testScriptTextIsAbsentAfterRemoval`; `testHiddenRangesCoverHiddenSubtreeOnly`; `testEmptyBodyGivesEmptyText`.
- `ChapterPipelineParityTests` (`@MainActor`, WebKit): for each fixture in `ChapterFixtures.base`, run it through `parse`, `body`, `removeActiveContent`, `bodyHTML`, load `<!doctype html><html><body>` plus that string plus `</body></html>` with
  `WKWebView.loadHTMLString(_, baseURL: nil)`, evaluate the `TreeWalker(document.body, SHOW_TEXT)` concatenation, and assert string equality with `ChapterText.extract(fromServedBodyHTML:).string`, plus a per-fixture marker offset check. Each fixture is its own assertion with the fixture name in the message.

Commands: `xcodegen generate`, `./test.sh`, `swiftlint` on touched files.
Done when: pure tests green; every base fixture passes parity in WebKit, or its mismatch is recorded in 5.7 with the owner's decision.
Must not touch: `EPUBParser.swift`, Reader, History.
Risk: SwiftSoup's HTML parser differs from WebKit on a fixture; mitigated by the parity test failing loudly. Rollback: delete the new files (nothing is wired).

#### Pass 3. DOM transforms, hide instead of delete

D1 is resolved: the indent transform is dropped. Objective: port the three remaining transforms (AO3 formatting, spacer tagging, preface hiding) to the DOM, with `hidden` replacing deletion.

Files: new `Sources/Content/ChapterTransforms.swift` (about 140 lines); `Sources/Parsing/EPUBParser.swift` CSS region (`readerCSS`): add
`[hidden] { display: none !important; }` next to the `p.ql-spacer` rule (CSS only, no offset effect; guards against a book rule such as `h2 { display: block !important }`). `INDEX.md`.

`ChapterTransforms.apply(options, hidePrefaceHeading:, to:)` runs in today's order (minus indents):
1. `formatAO3`: every `h2` whose class tokens include `toc-heading` gets `hidden=""` (was: removed with its content). Every `b` whose class tokens include `calibre2` gets
   `style` merged: existing value, then `;` if needed, then `font-size:1.5em;font-weight:700;display:block;margin:0.5em 0;` (was: a second `style` attribute appended). Token matching tightens the old substring match
   (`xtoc-headingy` no longer matches); record this in the pass report.
2. Paragraph indents: not ported (D1). `removeParagraphIndents` stays in `SettingsManager` and the Reading tab UI, but the pipeline ignores it, so turning it on has no effect until it is revisited (M4a, with a rendered check of whether HTML already collapses leading space and tab). Record this user-visible change in the pass 5 report and in `ARCHITECTURE.md`; removing or disabling the toggle in Settings is out of scope and left to the owner.
3. `markSpacers`: a `p` with at least one child node where every child is a whitespace-only text node (`trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, which includes NBSP) or a `br` element gets class `ql-spacer`, placed first
   in an existing `class` (`ql-spacer calibre7`), as today. An empty `<p></p>` is not a spacer.
4. `hidePrefaceHeading` (true only for resource 0, set by `ChapterPipeline`): every `h1..h6` with no child elements and text matching `^\s*[Pp]reface\s*$` gets `hidden=""` (was: removed).

Tests (`ChapterTransformsTests`, pure, plus fixtures appended to `ChapterFixtures`):
- `testTocHeadingIsHiddenNotDeletedAndTextStillCounted`; `testCalibre2StyleMergesWithExistingStyle`; `testTocHeadingTokenMatchIsExact`.
- `testLeadingIndentWhitespaceIsLeftUntouched` (tabs and spaces at the start of `p`, `div`, `li` remain in the output and in `ChapterText`).
- `testSpacerVariantsAreTagged` (the seven variants in `SpacerParagraphTests.builtHTML` fixture: NBSP, `&#160;`, `&nbsp;`, whitespace and newline, `<br/>`, `&#xA0;`, plus class merge order), `testRealParagraphsPreAndParamAreNotTagged`, `testEmptyParagraphIsNotASpacer`.
- `testPrefaceHeadingHiddenOnlyWhenRequestedAndOnlyExactText` (`Preface`, ` preface `: hidden; `Prefaces`, `Preface <i>x</i>`, `PREFACE`: not hidden, matching today's `[Pp]reface`).
- `ChapterPipelineParityTests.testTransformFixturesKeepJSAndSwiftTextEqual` and `testHiddenElementsKeepOffsetsIdenticalToUnhiddenText` (WebKit: text with the `hidden` attribute present equals text without it, and the heading's `getComputedStyle(...).display` is `none` under `readerCSS`).

Commands: `./test.sh`, `swiftlint` on touched files.
Done when: tests green; `[hidden]` rule present in `readerCSS`.
Must not touch: render and search call paths (still on the regex helpers), `ServedChapter`.
Risk: low, nothing wired. Rollback: delete the file and the CSS line.

#### Pass 4. URL rewriting in the DOM; the `ChapterPipeline` facade (still not wired)

Objective: complete the pipeline end to end as a pure function. Decision D2 (default: do it here).

Files: new `Sources/Content/ChapterURLs.swift` (about 90 lines), `Sources/Content/ChapterPipeline.swift` (about 90 lines). `INDEX.md`.

`ChapterURLs.rewrite(in:chapterURL:root:)`: for every element, for attributes `src`, `href`, `xlink:href`: leave the value alone when empty, when it begins with `#`, or when it already has a URL scheme
(`URLComponents(string:)?.scheme != nil`, case-insensitive; replaces the old `http` prefix test, so `http-notes.xhtml` is rewritten). Otherwise split at the first `#`, percent-decode the path with `removingPercentEncoding ?? path`, resolve against
`chapterURL.deletingLastPathComponent()` (a leading `/` resolves against `root`), standardize with `standardizedFileURL`, and when the result is not inside `root` remove the attribute. Write the result as `absoluteString`, then re-append the fragment
percent-encoded with `.urlFragmentAllowed`. Output stays `file:` URLs because the default path still loads a file URL (R5/M4a replace the scheme later).

`ChapterPipeline.render`: read bytes, `ChapterDecoder.decode`, `ChapterMarkup.syntax`, `parse` (XML, then HTML on throw, then `""`), `body`, `removeActiveContent`, `ChapterTransforms.apply(options, hidePrefaceHeading: resource == 0, ...)`, `ChapterURLs.rewrite`, `bodyHTML`.
`text`: same up to the transform step with URL rewriting skipped (it does not change text), then `ChapterText.extract(fromServedBodyHTML: bodyHTML)`. The `mediaType` argument is `pkg.manifest[pkg.spine[i].manifestID]?.mediaType`; `spineURLs` and `spine` alignment is Unverified (verify list).

Tests (`ChapterURLsTests`, `ChapterPipelineTests`, pure; `ChapterPipelineParityTests` extended with the `urls` fixtures):
- `testNestedChapterImageResolvesFromChapterDirectory`, `testParentDirectoryReferenceStaysInsideRoot`, `testReferenceEscapingRootIsDropped`, `testSingleQuotedAndPercentEncodedAttributesResolve`, `testCrossChapterHrefKeepsFragment`,
  `testSchemeURLsAndFragmentOnlyLinksAreUntouched`, `testRelativePathBeginningWithHttpIsRewritten`, `testXlinkHrefIsRewritten`, `testSpaceInFileNameIsPercentEncoded`.
- `testRenderRemovesActiveContentAndRewritesURLsAndHidesPreface` (end to end on a temp chapter file), `testOptionsFlowThroughToTransforms`, `testMalformedXMLFallsBackToHTML`, `testUnparseableChapterReturnsEmptyBody`, `testLatin1ChapterWithXMLDeclarationDecodes`.

Commands: `./test.sh`, `swiftlint`.
Done when: tests green. Owner records the pre-wiring baseline for the throughput gate by running `ReaderBaselineTests` on this tree and keeping `build/diagnostics/` output (it times the regex path). The owner also records the eight large-book numbers of section 6 item 1 for the largest local EPUB (open time, WebContent memory, one font-size change, fast-scroll behavior) before pass 5, because the M4a gate compares against them and pass 5 changes the default path.
Must not touch: `EPUBParser.swift`.
Risk: URL semantics differ from the regex for edge inputs; the pass 5 test updates pin the intended behavior. Rollback: delete the two files.

#### Pass 5. Wire the render path; delete the render-side regex code

Objective: `buildScrollHTML` and `buildPageHTML` get their bodies from `ChapterPipeline.render`.

Files (`Sources/Parsing/EPUBParser.swift`):
- `extractedChapterBody(from:index:base:formatFirstChapter:removeParagraphIndents:collapseSpacerParagraphs:)` keeps its name and signature, body becomes
  `ChapterPipeline.render(chapterAt: pkg.spineURLs[index], mediaType: ..., resource: index, root: pkg.rootFolder, options: .init(formatAO3: formatFirstChapter, markSpacers: collapseSpacerParagraphs))`. The `removeParagraphIndents` parameter is accepted and ignored (D1), which keeps both builders and every caller untouched. Delete `stripLeadingIndentWhitespace` with the others.
- Delete `extractBody`, `rewriteResourceURLs`, `stripLeadingIndentWhitespace`, `markSpacerParagraphs`, `spacerParagraphPattern`, `stripPrefaceHeading`, `applyFirstChapterFormatting` (`import SwiftSoup` is not needed in this file; the pipeline hides it). Keep the private `String` extension until pass 6 (still used by `searchableText`).
- `INDEX.md` line ranges via `scripts/index-anchors.sh`.

Test changes (named):
- `SpacerParagraphTests`: replace string assertions by parsing the built HTML with SwiftSoup's HTML parser: `testSpacerParagraphsAreTaggedWhenEnabled` asserts `p.ql-spacer` count equals 7 and that class order is `ql-spacer calibre7` where the source had a class;
  `testRealParagraphsAndNonParagraphElementsAreNotTagged` asserts by selector; the disabled case asserts zero.
- `WebKitOffsetParityTests.testSyntheticFixtureCapturesKnownResourceAndLinkBugs`: remove the three `XCTExpectFailure` wrappers (nested image, single-quoted and encoded image, cross-chapter href) and assert the serialized double-quoted form; change the anchor assertion from
  `<a id="self-closing"/>ANCHOR_MARKER` to `<a id="self-closing"></a>ANCHOR_MARKER`. Keep the offset parity `XCTExpectFailure` (B1): section wrapper whitespace is unchanged, so it must still fail; if it unexpectedly passes, stop and report.
- `ReaderBaselineTests`, `ReaderBaselinePagedTests`, `ReaderBaselineScrollTests`: unchanged, they must pass.
- `ChapterPipelineParityTests.testBuiltScrollDocumentSectionTextMatchesSwiftText` (WebKit): load `buildScrollHTML` output for a 3 chapter synthetic book, walk each `section.ql-chapter` and equal `ChapterPipeline.text` for that resource (per-section parity, not whole document).
- `ChapterHostOffsetParityTests` and the other `ChapterHost*` tests: unchanged, must pass (host is on raw bytes, see F9).

Commands: `./test.sh`, `swiftlint` on touched files. Owner click-through: open one real EPUB in scroll and paginated mode, check images in a nested chapter, an AO3 book with Format for AO3 on, a book with an active `<script>` (positive control: no script effect).
Done when: all tests green; `grep -nE 'extractBody|rewriteResourceURLs|stripPrefaceHeading|markSpacerParagraphs|applyFirstChapterFormatting|stripLeadingIndentWhitespace' Sources` returns nothing.
Must not touch: `searchResults`, `speechText`, `ReaderViewController`, `ServedChapter`, `ChapterHost*`.
Risk: visible rendering differences (images that now resolve; hidden instead of removed headings; HTML serialization of odd markup). Rollback: revert the pass (the pipeline files stay, unused).

#### Pass 6. Wire the text path; honor the toggles; delete the spike

Objective: search and speech use `ChapterPipeline.text` with the real settings, and skip hidden text.

Files:
- `Sources/Parsing/EPUBParser.swift`: `searchResults(for:in:limit:)` becomes `searchResults(for:in:limit:options:)` with `options: ChapterTransformOptions = .init()`; it uses `ChapterPipeline.text`,
  matches against `text.string`, and skips any match whose range intersects `text.hiddenRanges`. `speechText(in:at:)` gains the same `options` parameter and returns `text.string` with hidden ranges removed (empty result still returns nil).
  Delete `searchableText` and the private `String` extension (after the Sources-wide grep, F13).
- New `Sources/Settings/ChapterTransformSettings.swift` (about 20 lines): `extension ChapterTransformOptions { static func current(from settings: SettingsManager) -> ChapterTransformOptions }` reading `formatFirstChapter` and `collapseSpacerParagraphs` only. L2 stays free of settings.
- `Sources/Reader/ReaderViewController.swift`: the two call sites (search around the `SearchBarDelegate` extension, `EPUBParser().searchResults`; speech in `AVSpeechSynthesizerDelegate.didFinish`, `parser.speechText`) pass `.current(from: SettingsManager.shared)`. Read by range with the INDEX section map; this file has no tests, say so.
  Also use the same options at the initial speech call (`speakCurrentLocation`; locate it by symbol, not line number).
- Delete `Tests/HoneycrispTests/SwiftSoupSpikeTests.swift` (FRAMEWORK rule 4: spike deleted once promoted). Its expected failure `testRegexEntityDecodingDoubleDecodesAmpersandEntities` would now unexpectedly pass and fail the suite; its serialization, offset, removal and spacer cases are covered by passes 2 to 4.
- `INDEX.md`, test table updates.

Tests:
- Keep `EPUBParserTests` search test (expects offset 18 for the emoji, `&amp;` fixture) unchanged.
- `ChapterSearchTests`: `testSearchOffsetsEqualRenderedOffsetsWhenAO3FormattingIsOn` (the F6 regression: an AO3 `toc-heading` fixture, option on, search offsets equal `ChapterText` offsets of the rendered body); `testSearchSkipsMatchesInHiddenPrefaceAndTocHeading`; `testSpeechTextOmitsHiddenText`;
  `testDoubleEncodedAmpersandOffsetIsExact` (`&amp;lt;` fixture); `testSearchHonorsLimitAcrossChapters`; `testEmptyQueryReturnsNothing`.
- `ChapterPipelineParityTests.testSearchOffsetPlusMarkerEqualsWebKitWalkOffset` (WebKit): for markers in the entities, supplementary, whitespace and self-closing fixtures, `searchResults` offset equals the JS walk offset of the served body.

Commands: `./test.sh`, `swiftlint` on touched files.
Done when: tests green; `grep -n 'searchableText\|replacingOccurrences(of:.*) {' Sources` empty; no regex remains in `EPUBParser` for HTML structure (remaining regex is L0: `parseLandmarks`, language tag checks, and the excerpt whitespace collapse in `searchResults`).
Must not touch: `HistoryManager`, `Locator`, host files.
Risk: search results change when the toggles are on (corrected); speech skips text it used to read (preface, toc heading). Rollback: revert the pass.

#### Pass 7. Concurrency and throughput

D5 is resolved: no hard budget. Objective: parse chapters concurrently and record numbers for reference.

Files:
- `Sources/Content/ChapterPipeline.swift`: `renderAll(count:_:)` using `DispatchQueue.concurrentPerform(iterations:)` writing into a pre-sized buffer guarded by `NSLock`; results returned in index order; the first thrown error (lowest index) is rethrown;
  `static let maxConcurrency` clamps to `ProcessInfo.processInfo.activeProcessorCount` and is the rollback lever (set to 1 for sequential). Swift 5.9 mode: no `Sendable` diagnostics to satisfy; keep the closure non-escaping.
- `Sources/Parsing/EPUBParser.swift`: `buildScrollHTML` builds all chapter bodies with `renderAll`, then concatenates sections in order. `searchResults` collects per-chapter texts with `renderAll`-style concurrency while keeping result order and the `limit` (compute texts concurrently, scan sequentially).
  The call stays synchronous on the caller's thread: `buildScrollHTML` still blocks the main thread for its (now shorter) duration. Moving the load off the main thread belongs with the M4a load rewrite (D7).
- Tests:
  - `ChapterPipelineConcurrencyTests.testConcurrentRenderIsByteIdenticalToSequential` (64 synthetic chapters, 8 repetitions, compares to `maxConcurrency = 1`), `testErrorFromLowestIndexIsRethrown`, `testResultsAreInIndexOrder`.
  - `ChapterPipelineThroughputTests.testThroughputIsRecorded`: generates one 150 KB chapter and a 300-chapter book from `SyntheticBook`, three runs, median each: `render` of the 150 KB chapter; `renderAll` over 300 chapters sequential and concurrent;
    `searchResults` over 300 chapters; `buildScrollHTML` on the 2,000-page fixture. Writes `pipeline-throughput.txt` through `TestDiagnostics.write`. It asserts only correctness (concurrent output equals sequential output); it has no time assertion.

Commands: `./test.sh`; owner records the numbers from `build/diagnostics/pipeline-throughput.txt` in the roadmap M6 text (machine, OS, Xcode, median of three).
Done when: concurrency test green with no differences from sequential output; the owner opens a large real book and judges speed acceptable.
Risk: SwiftSoup is not safe for concurrent use (Unverified); the byte-identical test is the detector and `maxConcurrency = 1` is the rollback. Memory: peak grows with concurrent documents; the 2,000-page baseline `ReaderBaselineTests` must stay within its existing 124 MB reference.

#### Pass 8. Layout bump, gate, documents

Objective: ship the offset change deliberately and close the milestone.

Files:
- `Sources/Reader/PaginationEngine.swift`: `EPUBAnchor.currentLayout = 2`; `legacyLayout` stays 1. Update the comment above it to name `ChapterPipeline`, `ChapterText` and the transforms instead of `extractedChapterBody` and `searchableText`.
- Docs: `docs/ROADMAP.md` (M6 `Status: complete` with the pass 7 numbers; the M6, M4a and M5 design text was already corrected by docs pass 0, so only the status and numbers change here);
  `ARCHITECTURE.md` (section 4 render path, section 5a layout 2 and what changed, 4a note that flag mode offsets are over raw chapter bytes and equal pipeline text only for chapters without active content, section 7 untouched); `INDEX.md` (regenerate ranges, new `Sources/Content` map, tests table);
  `CLAUDE.md` zip copy (invariants: "Scroll and paginated modes share `extractedChapterBody`..." now `ChapterPipeline`; layout paragraph; Doc drift paragraph); `docs/FRAMEWORK.md` C2 and C6 wording that names `searchableText` or `EPUBParser.javaScriptStringLiteral` only if now wrong.
- Tests: `LocatorTests.testSavedLayoutOneRestoresByFractionAndLayoutTwoByOffset`; `HistoryEntryTests` unchanged expectation `legacyLayout == 1` decode; `HistoryManagerTests` carry-forward of an old entry's layout stays (existing test, must pass);
  `BookmarkManagerTests` legacy bookmark decodes to layout 1 (existing); `ChapterPipelineParityTests.testEveryFixtureSetPassesParity` (loops base, transforms and urls sets, one failure message per fixture name).
- Exit checks (commands in the pass report): `grep -rn 'SwiftSoup' Sources | cut -d: -f1 | sort -u` lists only `Sources/Content/*`; no `<script>`, `on*` or `javascript:` in any rendered fixture body (asserted in `ChapterMarkupTests` and a build-level assertion over `buildScrollHTML` on the synthetic book).

Commands: `./test.sh`, `swiftlint` on touched files.
Done when: all tests green; roadmap M6 `Status:` says complete with measured numbers; owner confirms an old saved position in a real book restores approximately (fraction) after the bump.
Risk: every saved position and bookmark saved at layout 1 now restores by fraction (less exact, once). Rollback: set `currentLayout` back to 1; offsets saved at 2 in the meantime would then be treated as layout 1 offsets, so only roll back before shipping.

### 5.6 Order and dependencies

1 then 2 then 3 then 4 are independent of the running app (nothing wired) and each depends on the previous file. 5 needs 4. 6 needs 5 (shared pipeline) and 3 (hidden ranges). 7 needs 6. 8 last.
No pass is blocked on a decision. Pass 1 can start now. The owner's pre-wiring baseline (pass 4 note) must be recorded before pass 5.

### 5.7 Decisions needed

Resolved: adding SwiftSoup as an app dependency (R5, and the owner's instruction to assume it works); the layout bump (M6 gate). Recorded in pass 1 and pass 8, not re-asked.

Resolved by the owner:
- D1: do not port the paragraph-indent transform; `removeParagraphIndents` is a no-op in the pipeline for now. The setting and its UI are left in place.
- D5: no throughput budget; the owner judges speed by feel. Numbers are still written to `build/diagnostics/pipeline-throughput.txt`.

Blocking: none.

Non-blocking (defaults proposed):
- D2: rewrite URLs in the DOM during M6 (pass 4), resolving from the chapter's directory, which fixes F5. Alternative: leave `rewriteResourceURLs` for M5, which keeps a regex on serialized HTML and leaves the pinned expected failures. Default: do it.
- D3: add the XML declaration encoding to the charset order (roadmap lists BOM, meta charset, UTF-8, windows-1252). Default: add.
- D4: leave `ServedChapter.prepare` string-level and the host on raw bytes; M4a replaces both. The M6 exit criterion is scoped to the L2 chapter body pipeline. Default: leave.
- D6: new L2 files under `Sources/Content/` (FRAMEWORK target home) rather than `Sources/Parsing/`. Default: `Sources/Content/`.
- D7: concurrency inside a synchronous call now; asynchronous off-main loading with M4a. Default: as stated.
- D8: unknown named entities (`&nbsp;` in XHTML) or other XML errors: retry the chapter as HTML, then empty body. Default: as stated; recorded counts go to `build/diagnostics/pipeline-fallbacks.txt` only if the owner wants them.

Decision for M4a, not blocking M6 (X1 in section 8): after this plan's bump, scroll mode still saves `spineIndex` 0 plus a whole-document offset
(`ReaderViewController.didReceivePosition`). M4a's section-rooted walk reads that number as a per-chapter offset, so layout-2 positions would restore to the
wrong place unless M4a bumps again (recommended: layout 3, fraction fallback) or maps them. Owner approval is needed before M4a pass 6.

Follow-ups noted, not done here: a chapter that fails both parses renders as an empty body (today's behavior); an explicit per-chapter error section, suggested in
the engine discussion, is left to M4a. `formatAO3` toc-heading hiding becomes redundant once the R21 harvest hides it for every book (M4a). `ChapterURLs` writes
`file:` URLs; M4a retargets it to the app scheme.

Known gaps to state in the pass reports (no decision needed): flag mode offsets are over raw bytes while default search is over pipeline text (F9); merged-document offset parity remains an expected failure until M4a (B1); hidden text is counted in offsets but masked in search and speech only for elements carrying `hidden` (CSS `display:none` from book styles arrives with the R21 harvest);
untested areas touched: `ReaderViewController` search and speech call sites, `SettingsManager` reads (no tests exist for either).

### 5.8 Verify before coding

1. `./test.sh` passes at 91c0dfd with the current tree (roadmap M0 still owes this); the plan base was not built.
2. SwiftSoup 2.14.3 builds in the app target under `SWIFT_VERSION: "5.9"` and the sandbox settings; whether the test target also needs its own `SwiftSoup` link.
3. `Parser.xmlParser()` on: named HTML entities (`&nbsp;`), XHTML DOCTYPE with public id, `<?xml ?>` declaration, namespace prefixes (`xhtml:body`), uppercase tags. What it throws versus tolerates.
4. Output: `Document.outputSettings().prettyPrint(pretty: false).syntax(syntax: .html)` exact API; `Element.html()` honors them; empty non-void elements serialize as `<x></x>`; void elements as `<br>`; `charset(.utf8)` leaves non-ASCII raw.
5. `TextNode.getWholeText()` versus `text()` (only the former is whitespace exact); `SwiftSoup.parseBodyFragment` behavior for a leading newline after `<pre>`, for CRLF, and for whitespace in tables, compared with WebKit (pass 2 parity decides).
6. SwiftSoup thread safety for concurrent independent parses (pass 7 test decides).
7. `String(data:encoding:.windowsCP1252)` returns nil for undefined bytes (0x81, 0x8D, 0x8F, 0x90, 0x9D); `CFStringConvertIANACharSetNameToEncoding` mapping for `utf-8`, `iso-8859-1`, `windows-1252`, `shift_jis`.
8. `EPUBParser.parseOPF`: `package.spineURLs` and `package.spine` have equal count and order (non-linear items), so `pkg.spine[i].manifestID` is the right manifest key for index `i`.
9. `[hidden] { display: none !important; }` under `readerCSS` does not change any existing `ReaderContrastTests` or `ReaderStyleTests` assertion (some assert on CSS text).
10. Tests that hard-code layout 1 or assert `currentLayout` literal values: grep `Tests/HoneycrispTests` for `anchorLayout` and `currentLayout` before pass 8.
11. Whole-`Sources` grep for other users of the private `String.replacingOccurrences(of:with:)` closure helper and of each deleted function before pass 5 and pass 6.
12. `WebKitOffsetParityTests.testOffsetParityForEntitiesUnicodeWhitespaceAndSelfClosingAnchor` still fails (so its `XCTExpectFailure` still holds) after pass 5.
13. `ChapterHostOffsetParityTests` still passes after pass 6 (host raw text versus pipeline text on its marker fixture).
14. Whether the first speech call (`speakCurrentLocation`) reads text through `speechText` or through a JS path; locate by symbol before editing pass 6.
15. Where `Package.resolved` and Xcode's own resolution record the SwiftSoup revision; do not hand-write a SHA.


## 6. After M6 (direction only; write a handoff plan for each before coding)

Each item needs its own plan with passes, named tests and gates. Gates below are fixed now so they are not invented later.

M4a, flow surface on the pipeline (ROADMAP M4a; needs M6):
1. Owner records, before M6 pass 5, the large-book baseline: for the largest local EPUB in 2.2.1 and with `HONEYCRISP_CHAPTER_HOST=1`, open time, "Honeycrisp Web Content" memory (not the app process), one font-size change latency, fast-scroll behavior (eight numbers). Kept in a handoff note, not a repo document.
2. `FlowingSurface` protocol, behavior-neutral: `ChapterHostSurface` and the merged path conform; the 16 `chapterHost` use sites in `ReaderViewController` (Verified at 91c0dfd: lines 204, 225, 571, 601, 682, 858, 1078, 1118, 1341, 1385, 1439, 1484, 1803, 2069, 2075, 2083; the declaration is line 41) move behind it. Existing tests pass unchanged.
3. `FlowDocumentBuilder` (section per chapter, N5, `ChapterURLs` retargeted to the app scheme, `HONEYCRISP_FLOW=1` flag, 307-chapter synthetic book).
4. Serve, isolate, restrict: scheme handler with the `text/html` override, content JavaScript off, client-world scripts (handlers per world as in `ChapterHostHandlers.swift`; test A1 in `ChapterHostShellTests` shows client-world scripts run with content JS off), CSP, remote-image policy, link policy reusing `ChapterHostSurface.allowsNavigation(to:)` (Verified use at `ReaderViewController` line 2075), load moved off the main thread.
5. R21 harvest (N3, N6), the same `[hidden]` rule in the served stylesheet. `formatAO3` toc-heading hiding becomes redundant for the flow surface (follow-up).
6. Positions: section-rooted walk, `Locator(resource, offset)`, history read and write; the second layout change (X1) and the mapping of older positions.
7. Default flip. Gate, all measured: per-section parity (C2) on every fixture; hidden text counted equally with and without the harvest; open time and WebContent memory no worse than 2.2.1 on the 2,000-page fixture (about 820 ms, 124 MB) and no worse than the recorded large-book numbers; author scripts do not execute; `<p/>` and `<a id="x"/>` fixtures render correctly; remote images do not load.
   Optional 7b, only if measured: chunked delivery, then a disk cache of normalized chapters (X4).
Exit: default path is the flow surface, the chapter host is still reachable through its flag, INDEX and ARCHITECTURE updated, the `CLAUDE.md` invariant about script restrictions corrected.

M5, port features onto the seam, one per PR: position save and restore, search and highlights, auto-scroll, speech, bookmarks, TOC jumps, in-book and cross-chapter links, navigation history (R13); then delete the merged path if X2 is confirmed; split `EPUBParser.swift` by layer.

M7, formats (open path hardcodes `epub` at `EPUBDropTargetView` line 39, `ReaderWindowController` lines 69 and 83, `AppDelegate` lines 95, 96 and 412, and `Honeycrisp/Info.plist` declares only `org.idpf.epub-container`; edit `Info.plist`, never the `.xcodeproj`):
- M7.1 HTML, Markdown, TXT as L0 adapters producing a `Publication`. Splitting (R22): `<article>` or generator containers (AO3 `#chapters`, rule Unverified), then headings, then `mbp:pagebreak`, then a size cap at paragraph boundaries; a failed split degrades to one chapter. TXT: normalize CRLF, treat a leading `> ` block as the header, split on `> N. Title`, scene-break lines (`***`, `---`, `* * *`) become `<hr>`. Markdown: small in-house converter for the fanfiction subset (X6). Output goes through the same pipeline.
- M7.2 PDF and M7.3 CBZ on `PagedSurface` (untouched by the engine decision).
- M7.4 MOBI/AZW3 via libmobi-swift converting to a temporary EPUB only if it builds for macOS (R9; no hand-written reader; licensing is not a gate); AZW3 yields split parts, MOBI 6 splits on `mbp:pagebreak`, non-zero encryption is reported as DRM (X5).

Chapter host resume (optional): only if the flow surface fails a measured large-book gate. Then it needs history, search, speech, bookmarks, TOC and links through the protocol, and size-based selection (X3).

## 7. Owner tasks (no code)

- Before M6 pass 1: check the Tests run for 91c0dfd in the Actions tab; finish the M0 leftovers (`CLAUDE.md` doc drift, README lint section).
- Before M6 pass 5: record the eight large-book numbers (section 6, item 1) and run `ReaderBaselineTests` on the pass 4 tree.
- After M6 pass 5: click-through of one real EPUB in scroll and paginated mode (nested-chapter images, an AO3 book with Format for AO3 on, a book with an active `<script>`).
- After M6 pass 8: confirm an old saved position restores approximately (fraction) in a real book.

## 8. Open decisions (none blocks docs pass 0 or M6)

| ID | Decision | Needed by | Recommendation |
|---|---|---|---|
| X1 | A second layout change in M4a. After M6, scroll mode still saves `spineIndex` 0 plus a whole-document offset (`ReaderViewController.didReceivePosition`; paginated mode saves a per-chapter offset). The section-rooted walk reads that number as a per-chapter offset, so layout-2 positions would restore wrongly. FRAMEWORK C1: bump when extraction changes which characters count. | before the M4a position pass | Bump to layout 3, older positions restore by fraction (`Locator.flowRestoreTarget`). Alternative: map whole-document offsets to `(resource, offset)`. |
| X2 | Delete the merged path (`buildScrollHTML`, `buildPageHTML`, `loadFileURL` sites at `ReaderViewController` lines 622 and 710) after the flow surface is default. | before M5 | Keep it as a `FlowingSurface` conformer through M4a; delete in M5 after the M4a gate and one release on the flow default. |
| X3 | Engine selection by book size or a setting (brushes the per-book reading mode non-goal). | only if a large-book gate fails | Defer; the env flag stays. |
| X4 | Disk cache of normalized chapters (persistence is `UserDefaults` only today). | only if measured first-open cost needs it | Defer. |
| X5 | MOBI/AZW3 decoder: libmobi-swift (R9). | M7.4 | Verify the macOS build and API first. |
| X6 | Markdown: in-house converter vs a package. | M7.1 | In-house, about 300 lines. |
| X7 | "Load remote images" setting. Default off is settled (R22). | M4a | Add the setting only if the owner wants it (privacy: one Fimfiction HTML hotlinks its cover). |

M6's own decisions D1 to D8 are in 5.7 (D1 and D5 resolved by the owner; the rest have defaults).

## 9. Verify before coding (beyond the M6 list in 5.8)

1. Whether `toc-heading` shows in 2.2.1 with Format for AO3 off. Code says it does in every chapter (`applyFirstChapterFormatting` runs only when the setting is on; `stripPrefaceHeading` removes only a heading that reads "Preface" at spine index 0); not observed.
2. CSP enforcement on `WKURLSchemeHandler` responses, and whether client-world scripts are exempt from a page CSP.
3. Repeated `didReceive` on one scheme task (chunked delivery).
4. Client-world handler registration for `readerJS` and `PaginationJS`.
5. `loading="lazy"` with the custom scheme; `content-visibility` on macOS 13 and 14.
6. A flow document served from `appResources` as `text/html` after the MIME override.
7. Structure inside AO3 HTML `#chapters`; libmobi-swift macOS build and API.
8. Memory of the right process (WebContent, not the app) for the 2,000-page fixture and the large book.
