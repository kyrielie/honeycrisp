# Plan: findings from the terminal-reader and Quick Look survey

Status: draft outline, inspection only. Nothing was built or run. Every Honeycrisp claim is from
reading code at commit `b4ab619` (`main`). Items marked "hypothesis" or "verify" are not confirmed.

Companion to `docs/reference-survey.md` (findings F1 to F12). IDs here use a `T` prefix so the two
lists do not collide. A second pass over the Swift repomix export is planned (section 11).

## 1. Purpose and scope

- Turn the second investigation into ordered, testable work for Honeycrisp.
- Sources: `repomix-output.xml` (bookokrat, hygg, gorae, epy, baca, lue, pdfgrep) and
  `epubquicklook.xml` (the Quick Look extension that inspired Honeycrisp).
- Licences were set aside by request. Revisit before copying any code (see section 10).
- Out of scope: library view, cross-book search, publisher CSS, quote sharing, per-window or
  per-book reading mode (`CLAUDE.md` non-goals).

## 2. What was read, and how deeply

| Source | Read | Not read |
|---|---|---|
| bookokrat | README; `jump_list.rs`, `annotations.rs`, `marks.rs` head, `bookmarks.rs` head, `comments.rs` structs, `dialog_anchor_migration.rs` head, `book_stat.rs` signatures | `main_app.rs`, `html_to_markdown.rs`, PDF pipeline, search engine |
| lue | README; `content_parser.split_into_sentences`; `timing_calculator.py` (partial); `progress_manager.py` head; PDF filter grep | `reader.py`, `ui.py`, TTS engines |
| baca, epy | READMEs; baca `ebooks/mobi.py`; KindleUnpack file inventory | KindleUnpack logic, epy sources |
| hygg | README; `cli-pdf-to-text` file inventory; identity grep | All logic, server, PWA |
| gorae, pdfgrep | README / file inventory only | Source |
| EPUB Quick Look | Everything (23 files) | Template tests contents |

## 3. Findings summary

| ID | Finding | Evidence | Kind | Effort |
|---|---|---|---|---|
| T1 | Bookmark store resets to empty on any decode failure or version mismatch; next save overwrites it | `ReadingBookmark.swift:31-38`, `:71`; bookokrat `comments.rs` `unparseable_entries` | Bug (code reading) | S |
| T2 | Search hits use fixed `#FFEE58` with `color: inherit`; about 1.2:1 for white text (hand calculation) | `EPUBParser.swift` `readerCSS`, `mark.ql-hit` (about l.1070-1078); bookokrat `annotations.rs` | Bug (not measured in app) | S |
| T3 | No back/forward after internal link, TOC, search, or bookmark jumps | `ReaderViewController.swift:1684` (only http(s) handled); grep found no back stack; bookokrat `jump_list.rs` | Feature | S to M |
| T4 | Speech continuation text comes from a regex stripper that joins blocks with no separator; first utterance comes from page JS | `ReaderViewController.swift:777`; `EPUBParser.swift:191`, `:204` | Bug (hypothesis: depends on source whitespace) | S |
| T5 | Speech has no sentence chunking or word highlighting | lue `split_into_sentences`, `create_word_mapping` | Feature | M |
| T6 | Quick Look: sample extension has defects to avoid and design choices to copy | `epubquicklook.xml` | Plan input | M to L |
| T7 | Positions carry no layout version | bookokrat `anchor_layout`, `dialog_anchor_migration.rs` | Hardening | S |
| T8 | Metadata model reads one `title` and one `creator` only | `EPUBParser.swift:227-228` | Feature | S |
| T9 | PDF reflow as text is undecided; roadmap says PDFKit only | `implementation-roadmap.md` format decision 2, Phase 4; hygg and lue | Decision | M to L |
| T10 | MOBI/AZW3: baca confirms the temp-EPUB bridge; KindleUnpack port rejected | baca `ebooks/mobi.py` | Confirmation | n/a |
| T11 | Moved or renamed files orphan bookmarks (keyed by normalized path); no surveyed project solves it | `ReadingBookmark.normalizedPath`; lue keys by sanitized title | Open question | M |

Not adopted: gorae (library, index, AI chat), hygg (sync server, shell commands, AI voices),
pdfgrep (PDFKit search covers Phase 4), bookokrat reading statistics (roadmap item 25 stays deferred).

## 4. Workstream A: data durability (T1, T7, T11)

Goal: no user data is lost on decode errors, downgrades, or parser changes.

Tasks
- A1. Decode bookmarks per element. Keep the raw JSON of entries that fail and write them back on
  save. Do not overwrite storage when the envelope version is newer than known.
- A2. Apply the same rule to `HistoryManager.load`, which discards the whole array on failure (the
  `HistoryEntry` comment describes this).
- A3. Add `anchorLayout: Int` (default 1) to `ReadingBookmark` and `HistoryEntry`, decoded with
  `decodeIfPresent`. Document the bump rule in `ARCHITECTURE.md`: bump when text extraction or
  chapter formatting changes character offsets.
- A4. Decide on file identity for moved files (T11): options are path only (today), path plus
  `dc:identifier`, or a content fingerprint. Record the decision before coding.

Tests (XCTest, in-memory `UserDefaults` suite)
- Corrupt entry among valid ones: valid ones load, corrupt one survives a save round trip.
- Unknown newer version: nothing is overwritten.
- Missing new fields decode with defaults (extend `HistoryEntryTests`).

Acceptance: a downgrade or one bad entry never deletes stored bookmarks or history.

## 5. Workstream B: small reader fixes (T2, T4a)

- B1. Search-hit contrast. Give `mark.ql-hit` an explicit text color, or derive the hit background
  from the theme. Pick a target ratio (bookokrat uses 3.0; WCAG AA text is 4.5). Review every
  built-in theme in light and dark. Add a test that the generated CSS sets an explicit color.
- B2. Speech separators. Insert a newline for block-closing tags before stripping in
  `searchableText`. Test with `<p>a.</p><p>b</p>` (no whitespace between blocks) and headings.
  Check whether search offsets depend on this function before changing it (search results keep
  UTF-16 offsets; see `testSearchResultsRetainChapterAndUTF16TextOffsets`).

Acceptance: hits are readable in all built-in themes; fused block text no longer occurs in speech.

## 6. Workstream C: navigation history (T3)

Design (from bookokrat `jump_list.rs`)
- New pure type `NavigationHistory`: bounded list of `(spineIndex, characterOffset)` plus a cursor.
- Push the origin before a jump. Going back from the newest entry saves the current location first.
- A deduplicated push must still reset the cursor (bookokrat regression test).
- Not persisted. Per window, in memory, which fits the one-window-per-book invariant.

Push points: internal link click, TOC selection, search result, bookmark jump, Start Reading.
Reuse `RestorePosition.characterOffset` and `pendingFragment` / `navigateToFragment` for landing.

Tasks
- C1. Implement and unit-test the type (port the three bookokrat tests).
- C2. Wire into `ReaderViewController`; add Back and Forward commands through `RebindableAction`
  so shortcuts stay user-editable and menus stay in sync.
- C3. Toolbar or menu affordance; disable when empty.

Note: `ReaderViewController` has no tests. Say so in the PR and keep logic in the tested type.

Acceptance: follow a footnote, go back, land on the origin offset in both reading modes.

## 7. Workstream D: speech (T4, T5)

Goal: sentence-level control and optional highlighting without fuzzy alignment.

- D1. One extractor. Use the DOM for every chunk, or share block-aware extraction, so first and
  later chapters match.
- D2. Chunking. Split into paragraphs, then sentences (abbreviation and initial protection as in
  lue `split_into_sentences`). Each chunk carries its start offset in the same units as saved
  positions (UTF-16 over the text-node walk).
- D3. Highlight. `AVSpeechSynthesizerDelegate` should report spoken character ranges per
  utterance. Verify the exact method in Apple docs. Map range plus chunk offset to a DOM Range.
  Behind a setting; off by default.
- D4. Click or key to speak from here (lue tracks chapter, paragraph, sentence).
- Gate: roadmap item 12 requires reliable speech-to-rendered-text mapping. D1 and D2 provide it.
- Tests: sentence splitter (abbreviations, initials, quotes), chunk offset arithmetic. Speech code
  itself has no tests today.

Acceptance: highlight tracks speech across paragraphs; pause, resume, and voice change keep position.

## 8. Workstream E: Quick Look (T6)

Goal: Honeycrisp ships a maintained Quick Look preview (roadmap Phase 8, request 27). It depends
only on the parser, so it can start before PDF or MOBI work.

Facts from the sample extension
- View-based `QLPreviewingController` with `WKWebView`; whole book merged into one page; JS on.
- Same parser shape as Honeycrisp (container.xml, `.opf` scan fallback, directory-bundle copy).
- Defects to avoid: temp folder `EPUBQuickLook_<UUID>` never deleted; `completionHandler(nil)`
  before content exists; no size cap; network-client and Downloads entitlements.
- Settings: macOS 14.6, Swift 5.0 mode, ZIPFoundation 0.9.19, stub host app.
- Plist lists `org.idpf.epub-container` and `com.apple.ibooks.epub`; Honeycrisp lists the first only.

Phases
- QL0 Preflight (S). Run `codesign -d --entitlements -` on a released app. `release.yml` builds
  unsigned then ad-hoc signs with no `--entitlements`; suspected entitlement loss (hypothesis).
  Test extension registration and load on a clean Mac. Decide signing path (ties to F4 in the
  reference survey).
- QL1 Skeleton (M). Add an `app-extension` target to `project.yml`, embedded in `Honeycrisp.app`
  (verify XcodeGen syntax). Plist with `NSExtension`, both content types. Sandbox plus
  user-selected read-only; remove network and Downloads unless a test proves them necessary.
  Decide deployment target (app is 13.0) and verify the Quick Look APIs available there.
- QL2 Shared core (M). Split `EPUBParser.swift` into core (models, unpack, OPF, landmarks, TOC
  helpers) and reader (HTML, CSS, JS). Check `ReaderCosmeticSettings` dependencies on
  `SettingsManager` first. Compile core into both targets from `project.yml`. No behavior change;
  run `./test.sh`.
- QL3 Stage 1 preview (M). Cover, title, author, metadata via a data-based reply (as Winston does).
  Typographic card when there is no cover. DRM and malformed files show a clear message.
- QL4 Stage 2 excerpt (M). First body chapter via `startReadingNode` / `firstSpineIndex`, with a
  byte cap, JS off, system light and dark. Read single archive entries instead of unzipping the
  book (verify ZIPFoundation 0.9.20 API).
- QL5 Hardening (M). Temp cleanup, timeouts, directory-bundle EPUBs, both content types, large
  book behavior. Evaluate a separate thumbnail extension (not investigated).
- QL6 Release (M). Signing and notarization decision, first-launch registration, README and cask
  notes, `pluginkit` check instructions.

Tests: preview builder against synthetic EPUBs (existing pattern). Finder behavior by hand:
`qlmanage -p`, `pluginkit`; confirm flags locally.

Acceptance (from Phase 8): installed Honeycrisp provides a dependable preview and a clear route
into the full reader. A build that only works from Xcode does not count.

Decision needed: raise Honeycrisp's handler rank above `Alternate` so Quick Look offers
"Open with Honeycrisp"?

## 9. Workstream F: PDF (T9) and others

PDF decision record
- Roadmap: PDFKit `PDFView`, no HTML conversion. This was not tested against your use case.
- For reflow: gains themes, fonts, columns, speech, search, and bookmarks for text PDFs.
- Against: tables, multi-column, math, and scans; hygg's converter spans about 45 files.
- Proposal: keep `PDFView` as default (Phase 4). Later add an optional "Reflow as text" mode for
  PDFs with a text layer: temporary HTML spine per page or page group into the existing pipeline;
  position is page index plus offset.
- Heuristics to try first (from lue): drop text starting in the top or bottom margin band (default
  10%, adjustable), short bottom-margin text as page numbers, join hard-wrapped lines, dehyphenate.
- PDFKit page text and line selections with bounds may support this. Verify names in Apple docs.
- Before deciding: add 3 to 5 PDFs to the local corpus (Phase 0 lists none): fanfic export,
  two-column paper, scan, table-heavy file. Record outcomes only, no content.
- If reflow is adopted, edit the roadmap line against forcing PDF into HTML abstractions.

Metadata and Book Info (T8)
- Extend `EPUBPackage` with language, publisher, identifier, date, description, series fields.
  Check fixtures before assuming AO3 or fichub files carry series metadata.
- Book Info sheet. Feeds Phase 9 and the file identity decision (A4).
- Store a text snippet with new bookmarks so menu entries are recognizable (bookokrat marks do).

MOBI/AZW3 (T10)
- No change to Phase 3. Validation matrix needs one MOBI7 and one KF8 file. baca distinguishes
  `mobi7/` (only `content.opf`) from `mobi8/` (has `container.xml`); Honeycrisp's `.opf` scan
  fallback covers the first if conversion output lacks `container.xml`.

## 10. Suggested order

1. A1, A2, A3 (data safety). B1, B2 (small fixes).
2. QL0 (blocks everything Quick Look, and informs signing).
3. C (navigation history).
4. QL1 to QL4.
5. D1, D2, then D3 and D4.
6. PDF corpus, then the reflow decision; F/T8 metadata.
7. QL5, QL6.

Each item is one PR-sized change with its own focused tests (`CLAUDE.md` testing rules).

Docs to update with the work
- `docs/implementation-roadmap.md`: Phase 8 (pull forward, new checklist), Phase 4 and format
  decision 2 (reflow decision), Phase 3 (MOBI7 and KF8 samples).
- `docs/reference-survey.md`: add T-findings as an appendix.
- `ARCHITECTURE.md`: anchor layout rule; navigation history; extension target.
- `INDEX.md`: new files and section maps.
- Licences: bookokrat, lue, baca, epy, KindleUnpack, and hygg have their own terms. Resolve before
  copying any code. Reimplementing from the described behavior avoids the question.

## 11. Verify before coding (not confirmed here)

- `AVSpeechSynthesizerDelegate` range callback name and behavior on macOS 13.
- PDFKit text and line-selection APIs and their bounds.
- `QLPreviewReply` supported content types, and minimum macOS for the Quick Look APIs used.
- XcodeGen `app-extension` embedding syntax.
- ZIPFoundation 0.9.20 single-entry read API.
- Whether `com.apple.ibooks.epub` affects Finder routing for Honeycrisp.
- App Group availability under ad-hoc signing (needed to share theme settings with the extension).
- Whether entitlements survive the release workflow (QL0).

## 12. Second pass: Swift repomix

Input needed: the Swift repomix export used for `docs/reference-survey.md` (not in this
conversation; upload it again).

Questions, by workstream
- E: Winston `PreviewProvider.swift` and scripts: data-based reply details, extension packaging,
  registration. Any Swift repo with thumbnail extensions?
- E / QL0: Octavo `release.yml` signing and notarization steps, and how it embeds extensions.
- F: Varq `PDFBookRenderer.swift` and `CBZBookRenderer.swift`: PDFKit usage, position model, outline.
  Does any Swift repo reflow PDF text?
- D: swift-toolkit TTS engine, content iterator, and locator for chunk and highlight design.
- A: Varq `BookLocator` and highlight anchor ADR; compare with the `anchorLayout` field.
- C: any Swift back/forward or navigation-history implementation.
- Phase 3: libmobi-swift macOS build status and error mapping.
- Tests: EPUBKit edge-case fixtures as ideas for synthetic fixtures.

Output: a dated appendix to this plan with file and line evidence, plus status updates to the
items above. Read targeted files by section; skip files over 100 KB unless required.

## 13. Open decisions for the owner

- PDF reflow: yes, no, or after Phase 4 with samples.
- Quick Look: pull Phase 8 forward; stage 1 only or stage 2 excerpt; default handler rank.
- File identity for moved files (A4).
- Contrast target: 3.0 or 4.5.
- Signing: stay ad-hoc or obtain a Developer ID (affects Quick Look reliability).
