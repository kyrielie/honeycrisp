# Honeycrisp unified roadmap and plan (DRAFT, decisions round 3 recorded)

Base: commit `b4ab619` (`main`) plus the uncommitted `.gitignore` and `make_upload_zip.sh` edits.
Nothing here was built or run. "Verified" means I read the cited code in this review. Everything else
is carried over from the source docs and still needs checking before coding.

Proposed to replace: `docs/implementation-roadmap.md` (phases, request disposition) and
`docs/terminal-readers-survey-and-plan.md` (workstreams A to F). Keep `docs/reference-survey.md` as the
evidence appendix (findings F1 to F12). Keep `docs/compatibility-corpus.md` and the settings plan as is,
with the small fixes in W0.

Decisions recorded in round 1 (owner replies): D1 yes, D2 later, D3 accept suggestion, D4 path only,
D6 no Developer ID. D5 has a recommendation awaiting confirmation. Items not touched by those decisions
remain unapproved. Round 2: PDF and other formats stay in scope (reader storage format unknown). Round 3:
D4 stays closed; series live in the same directory as the book, plus folders the user adds; the
optional styling feature is a Honeycrisp-added, source-style preface (W14), not restored publisher CSS.
Sister-app reference: `reader-theming-implementation-plan.md` (Ambrosia), mapped in section 8. Section 9
has the full table.

## 1. Product boundaries (unchanged)

Native macOS reader for local files. AppKit and WebKit. One window, view controller, and `WKWebView`
per book. `UserDefaults` persistence only. Non-goals: library view, cross-book search, publisher CSS,
quote sharing, per-window or per-book reading mode, translation, cloud or AI voices, sync, device
delivery, export, statistics and goals. No generic `Document` abstraction until a second format
exists (Phase W6 is the trigger).

## 2. What changed from reading the code (reconciliation)

Verified in code:

| Claim in docs | Result |
|---|---|
| T1: bookmark store drops data on decode failure or version mismatch | Confirmed. `BookmarkManager.init` sets `bookmarks = []` on any failure or `version != 1`; the next `save()` overwrites storage. |
| A2: `HistoryManager.load` discards the whole array on failure | Confirmed at `HistoryManager.swift:190-192` (`try?` decode of `[HistoryEntry]`). |
| F2: any `encryption.xml` is reported as DRM | Confirmed (`EPUBParser.swift:137-140`). Existing test uses an empty `<encryption/>` file. |
| F3: no path or size check on unzip | Confirmed in Honeycrisp code (single `unzipItem`, l.125). Whether ZIPFoundation 0.9.20 rejects traversal is not verified. |
| F1: no content isolation | Confirmed: `allowsContentJavaScript = true` (`ReaderViewController.swift:167`), `rewriteResourceURLs` passes `http`, `file`, `data`, `javascript` values through, navigation delegate cancels only activated http(s) links, `ENABLE_OUTGOING_NETWORK_CONNECTIONS: YES`. Runtime exploit not demonstrated. |
| T2: search hits use fixed `#FFEE58` | Confirmed the fixed background (`EPUBParser.swift:1071`). Contrast ratio is a hand calculation, not measured. |
| F4: ad-hoc signing, fixed build number | Confirmed (`release.yml`, `build-dmg.yml` run `codesign --force --deep --sign -` with no `--entitlements`; `CURRENT_PROJECT_VERSION: 1`). |
| Ambrosia plan Phase 1 applies: preference values are interpolated into CSS unvalidated | Confirmed for Honeycrisp: `readerVarsCSS` (`EPUBParser.swift:1051`) writes `fontFamily`, `backgroundCSS`, `textCSS`, `linkCSS` raw. How `effective*CSS` values are produced was not read. |
| "We strip styling" | Partly. `extractBody` drops the `<head>` (so linked and head styles go). No code removes inline `style=`, body `<script>`, `<style>`, `on*=` attributes, or `javascript:` hrefs (`rewriteResourceURLs` passes them through). Visual effect of surviving inline styles was not tested. |
| Sandbox can list sibling files | No. `ENABLE_APP_SANDBOX: YES`, `ENABLE_USER_SELECTED_FILES: readonly`, bookmarks app-scope entitlement (`project.yml`, entitlements file). A file chosen in the Open panel grants that file only, so sibling lookup needs a user-granted folder (standard sandbox behavior; confirm on device). |

Conflicts and corrections found between documents:

1. `CLAUDE.md` and the roadmap say to "keep script restrictions and resource URL validation". None exist
   in code today (F1 above). The invariant is aspirational. D2 deferred the fix (W2.3), so until then the
   `CLAUDE.md` text should say the restriction is not yet enforced (proposed in W0, needs your OK).
2. Plan B2 (add newlines in `searchableText`) is unsafe as written. `searchableText` feeds both
   `searchResults` (l.169) and `speechText` (l.200). Search results keep UTF-16 offsets that must line up
   with the JS text-node walk used for saved positions. Changing shared output can shift offsets. Revised
   in W3: add a speech-only extractor, or prove offsets are unaffected with tests first.
3. The roadmap request table says items 16 and 17 were "Completed in Phase 3". Phase 3 is MOBI/AZW3.
   Stale phase number. Fix in W0.
4. The roadmap gated all EPUB work on Phase 0 (on-device sample review). Data durability, hardening,
   and small fixes do not need samples. Decided: decoupled (D1). Phase 0 gates only W5 and W12.
5. Quick Look is Phase 8 in the roadmap and pulled forward in the survey plan. Unified below as W8 with a
   preflight that can start early.
6. PDF: roadmap says PDFKit only and no HTML abstraction. Survey plan T9 proposes optional reflow. Kept
   as an explicit decision (D6) with the roadmap text unchanged until decided.
7. Four Settings tabs in `ARCHITECTURE.md`, README, and the settings plan; code has five. `INDEX.md`
   is pinned to `5c3dd27`; HEAD is `b4ab619`.
8. Phase 0 sample list has no PDFs, but the PDF decision needs them.
9. Three ID schemes (request 1 to 29, F1 to F12, T1 to T11, plus phases). Unified here as W0 to W13, with
   a crosswalk in section 8.

## 3. Workstreams

Effort: S under a day, M a few days, L a week or more. Each item is one PR-sized change with focused
XCTest coverage unless stated. Untested areas touched must be called out in the PR (`SettingsManager`,
`KeyBinding`, `PaginationEngine`, `ReaderViewController`, search UI).

### W0. Documentation truth (S)

- Fix the phase number for requests 16 and 17.
- Correct Settings tab count (five) in `ARCHITECTURE.md`, README, settings plan.
- Complete the README architecture table. Refresh `INDEX.md` line ranges against HEAD.
- Add PDFs to the Phase 0 sample classes.
- Record resolved decisions from section 9 in this file.
- Proposed, needs approval: add one line to `CLAUDE.md` stating that script and URL restrictions are
  not yet enforced (see W2.3), so future work does not assume they exist.

### W1. Data durability (T1, T7, A1 to A4, F5 minimal)

Goal: a downgrade or one bad entry never deletes bookmarks or history.

- W1.1 (S) Per-element decode for bookmarks. Preserve raw JSON of entries that fail and write them back
  on save. Never overwrite when the envelope version is newer than known.
- W1.2 (S) Same rule for `HistoryManager.load`.
- W1.3 (S) Add `anchorLayout: Int` (default 1) to `ReadingBookmark` and `HistoryEntry`, decoded with
  `decodeIfPresent`. Document the bump rule in `ARCHITECTURE.md`: bump when text extraction or chapter
  formatting changes character offsets.
- W1.4 Closed by D4: file identity stays path only (today). No work. Known limit: moving or renaming a
  book orphans its bookmarks and history entry. Record this limit in `ARCHITECTURE.md`. W7 keys to the
  original source path, and W12 uses its own AO3 identifiers, so neither depends on a new identity scheme.
- W1.5 (M, optional, only if re-downloaded edited fanfiction is a real problem) Store href plus a short
  quote beside the offset for re-verification (F5). Hypothesis, untested.

Tests: corrupt entry among valid ones; newer unknown version untouched; missing fields decode to defaults
(extend `HistoryEntryTests`, `BookmarkManagerTests`, using an in-memory `UserDefaults` suite).

### W2. Untrusted content hardening (F2, F3, F1)

Order is deliberate: smallest and most testable first.

- W2.1 (S) DRM detection precision (F2). Reject only on real markers (LCP `license.lcpl`, ADEPT markers),
  not on font obfuscation alone. Read namespace URIs from Readium's definitions before coding. Tests: font
  obfuscation only, ADEPT, LCP. Per D3, a file with no DRM markers (including the empty `<encryption/>`
  in the existing test) is readable, so that test's expected result changes and the change is stated in
  the PR.
- W2.2 CLOSED by verification (round 3): ZIPFoundation 0.9.20 `unzipItem` rejects uncontained entry paths and uncontained symlinks, and checks CRC32. Only size and entry-count limits are absent (D20, recommendation: skip). Original text: Verify ZIPFoundation 0.9.20 traversal behavior from its source. If it does not reject, add
  destination containment, entry-count, and total-size limits in `unpackEPUB`. Tests with crafted
  synthetic archives.
- W2.3 (M to L) DEFERRED by D2. Not scheduled. Content isolation (F1), Varq-style: content rule list blocking non-`file:` URLs, author JS
  disabled, reader scripts moved out of inline `<script>` tags into user scripts or a client content world,
  five message handlers re-registered for that world, navigation confined to the extracted root.
  Write the real-WebKit positive-control test first (prove the unhardened behavior is observable), then
  harden. Highest regression risk in the plan because `readerJS` and `PaginationJS` are inline today
  (`EPUBParser.swift:368-370`, `443-444`). Verify WebKit API availability on macOS 13 from Apple docs.
  Port-from-Varq requires a copyright notice (MIT).
- W2.4 (optional, M) `WKURLSchemeHandler` for resources in place of the regex in `rewriteResourceURLs`.
  Only if W2.3 or rewrite gaps (single-quoted and unquoted attributes) prove painful.

- W2.5 (S, proposed, D14) CSS value sanitizer, from the Ambrosia plan Phase 1. A pure type that
  validates hex colors, font-family text, and numeric ranges before `readerVarsCSS` interpolates them
  (font names from the custom font store and persisted theme colors are the reachable inputs). Invalid
  values fall back to defaults, never partially cleaned. Pure, so testable even though `SettingsManager`
  has no tests. Independent of D2. Read how `effective*CSS` values are produced first.
- W2.6 (S, proposed, D14) Chapter-body active content, from Ambrosia plan Phase 2: remove body `<script>`,
  `on*=` attributes (quoted and unquoted), and turn `javascript:` hrefs into `#`, in the shared
  `extractedChapterBody` path so both modes get it. Reader scripts live outside the extracted body, so
  they are unaffected. This is a partial mitigation only (regex, not a parser) and does not replace W2.3.
  No visible change for normal books. Inline `style=` and body `<style>` removal is a separate styling
  policy question (D15) because it changes how existing books look.
- Note on porting Ambrosia Phase 3 (content JS off): not directly portable. Ambrosia delivers its scripts
  through `evaluateJavaScript`; Honeycrisp's `readerJS` and `PaginationJS` are inline `<script>` tags, so
  disabling content JS would stop them. This is why W2.3 stays expensive and deferred.

### W3. Small reader fixes (T2, T4)

- W3.1 (S) Search-hit contrast. Explicit text color on hits, theme-derived hit and active-hit
  backgrounds. Target per D5 (recommended: 4.5 for text over a hit; active hit kept visibly distinct; no hit-to-page ratio, see D5).
  Review all built-in themes, light and dark. Test that generated CSS sets an explicit color. Measure in
  app before and after.
- W3.2 (S) Speech block separators. Revised: do not change shared `searchableText` until a test proves
  search offsets are unaffected. Preferred: a speech-only extractor that inserts newlines at block
  boundaries. Tests: `<p>a.</p><p>b</p>`, headings, and a regression that
  `testSearchResultsRetainChapterAndUTF16TextOffsets` still passes.

- W3.3 (S, proposed, pending samples) Fake `&nbsp;` indents. `stripLeadingIndentWhitespace` skips
  `&nbsp;` by design. Extend to `&nbsp;`, `&#160;`, `&#xA0;`, U+00A0 only if samples show plain-text
  conversions use them. Stays behind the existing remove-indents setting. Offset effect: removing leading
  characters shifts offsets in affected chapters, so it needs the W1.3 layout-version rule and a test.
- W3.4 (S, optional) Media and wide-table backstops (Ambrosia plan Phase 5). Read current `readerCSS`
  first. A scroll container inside the paginated column flow can break page measurement, so test both
  modes with a synthetic wide-table fixture, or apply only in scroll mode.

### W4. Navigation history (T3) - new feature

Pure `NavigationHistory` type: bounded list of `(spineIndex, characterOffset)` plus cursor, in memory per
window, not persisted. Push origin before internal link, TOC, search result, bookmark jump, Start Reading.
Going back from the newest entry saves the current location first. A deduplicated push must still reset
the cursor.

- W4.1 (S) Type plus unit tests (three bookokrat-derived behaviors, reimplemented).
- W4.2 (S to M) Wire into `ReaderViewController`; Back and Forward as `RebindableAction` so shortcuts
  stay editable and menus sync. Reuse `RestorePosition.characterOffset` and `navigateToFragment`.
- W4.3 (S) Menu and toolbar affordance, disabled when empty.

Acceptance: follow a footnote, go back, land on the origin offset in scroll and paginated modes.
Requires approval as a new feature (D10).

### W5. EPUB and KEPUB compatibility (old Phases 0 and 1, requests 6, 7, 26)

Owner-driven, on-device, no repository content. Does not block W1 to W4.

- W5.1 Record source and redistribution status per sample in `docs/compatibility-corpus.md`
  (observed technical outcome kept separate from license status).
- W5.2 Run EPUB2, EPUB3, AO3, fichub, FicLab, FimFic, Gutenberg, Standard Ebooks, browser-generated, and
  KEPUB samples through Open, TOC, links, scroll, pagination, search, resume. Fix general issues before
  source-specific ones, each with a synthetic regression test.
- W5.3 KEPUB: narrow compatibility handling based on observed markers only; same pipeline and position
  storage.
- W5.4 Compare against EPUBKit only on the corpus. Do not add as a dependency (rejected in survey).
- Implemented and retained: hide images, skip cover when opening (explicit cover landmark, fresh position
  only).

Acceptance: validated, failed, and untested are distinguished per sample class.

### W6. Format-aware open boundary and PDF (Phases 2, 4, 5; requests 2, 3; T9)

Rationale (owner, round 2): the reader's preferred storage format is unknown, so PDF and other formats stay in scope.

- W6.1 (M) One supported-types registry used by Open panel, drag-and-drop, Finder events, Open Recent
  validation, with extension plus content validation. Explicit unsupported-format error for MOBI-family
  until W7 passes.
- W6.2 (M to L) PDF via PDFKit `PDFView`. Zero-based physical page index stored separately from EPUB
  spine and offset; safe restore if page count changes; native outline; configurable displayed page
  offset; app-owned editable outline fallback (request 3); PDFKit search and selection. Tests for open
  failure, page restore, malformed or empty documents.
- W6.3 (M) Persistence audit once two formats work: format-discriminated, versioned records for history
  and bookmarks, with migration tests. Shared shell limited to title, file identity, open state.
- W6.4 Decision gate D6: optional "Reflow as text" for text-layer PDFs. Collect 3 to 5 local PDFs first
  (fanfic export, two-column paper, scan, table-heavy file); record outcomes only.

Reference: Varq `BookRenderer` is a worked example. Its PDF renderer was not read. Roadmap rule stands:
no protocol until the second format shows a real shared contract.

### W7. MOBI and AZW3 import (Phase 3, F7, T10) - dependency gated

Rationale (owner, round 2): kept in scope for the same reason as W6. D9 (LGPL) stays open.

Gate order: macOS build of `libmobi-swift` (manifest declares iOS only), license review (LGPL C headers
under a CC0 wrapper; static linking into an MIT app is the owner's call, D9), MOBI7 and KF8 sample
outcomes, DRM and error mapping, memory behavior. Then temporary EPUB conversion in an app-owned
directory, cleaned up reliably, history and bookmarks keyed to the original file (depends on W1.4). If
any gate fails: remain unsupported and document an external conversion workflow. No sample prose in the
repo.

### W8. Quick Look extension (Phase 8, requests 19, 27, T6, F10) - SHELVED

Status: shelved by D8 (no Developer ID makes reliable distribution doubtful). May move to a separate
repository. Nothing in this repo should change for it, in particular no `EPUBParser.swift` split (QL2)
until the work is revived. If revived, it can be built as its own repo that vendors or copies the parser
core. The plan below is kept for reference.

Independent of PDF and MOBI; depends only on the parser. Order within the stream:

- QL0 (S) Preflight: `codesign -d --entitlements -` on a released app; test registration on a clean Mac;
  decide signing path (links to W9). Suspected entitlement loss in the ad-hoc release is a hypothesis.
- QL1 (M) `app-extension` target in `project.yml` (verify XcodeGen syntax), sandbox with read-only user
  files, no network or Downloads entitlements unless a test proves need. Decide deployment target (app is
  13.0) after checking Quick Look API availability.
- QL2 (M) Split `EPUBParser.swift` into core (models, unpack, OPF, landmarks) and reader (HTML, CSS, JS).
  Check `ReaderCosmeticSettings` coupling to `SettingsManager` first. No behavior change.
- QL3 (M) Stage 1: cover, title, author, metadata via data-based reply; typographic fallback card; clear
  DRM and malformed messages.
- QL4 (M) Stage 2: first body excerpt via `startReadingNode`, byte cap, JS off, system light and dark.
  Single-entry archive reads (verify ZIPFoundation API).
- QL5 (M) Hardening: temp cleanup, timeouts, directory-bundle EPUBs, both content types
  (`org.idpf.epub-container`, `com.apple.ibooks.epub`), large books, evaluate thumbnails.
- QL6 (M) Release path, first-launch registration, README and cask notes, `pluginkit` and `qlmanage -p`
  verification steps.

Defects to avoid from the sample extension: undeleted temp folder, early `completionHandler(nil)`, no
size cap, network-client and Downloads entitlements. Acceptance: a build that only works from Xcode does
not count.

### W9. Release and signing (F4, Sparkle) - REDUCED

Per D8 there is no Developer ID: releases stay ad-hoc signed, Sparkle is skipped, and the Octavo-style
notarization flow is not adopted. Remaining work is small: keep the existing tag-driven release,
keep the Gatekeeper instructions in the README, and let Homebrew (`brew upgrade --cask honeycrisp`)
be the update path. Revisit only if a Developer ID is obtained.

### W10. Speech (requests 12, 23, T4, T5, F8)

Gated on reliable speech-to-text mapping, which W10.1 and W10.2 provide. Native macOS voices only.

- W10.1 (S to M) One extractor for all chapters (builds on W3.2).
- W10.2 (M) Paragraph and sentence chunking with abbreviation and initial protection; each chunk carries
  a start offset in saved-position units.
- W10.3 (M) Word highlight from `AVSpeechSynthesizerDelegate` range callbacks (verify exact method and
  macOS 13 behavior first). Off by default.
- W10.4 (S) Speak from here; voice filtering and rate controls; explicit state machine for start, stop,
  finish races (F8).

Tests for splitter and offset arithmetic; speech code itself remains untested.

### W11. Input, menus, and reading aids (requests 1, 8, 9, 10, 11, 15, 21, 22, 24)

Status of each was not re-audited in this review. First task (S): audit current implementation against
the request table and mark done, partial, or open. Known direction: full-window drop target (1), media
key and clicker support only where macOS exposes keyboard or media events (8), page and scroll buttons
in menus and toolbar (9), hold-to-change auto-scroll speed with clamping and release handling (10),
auto-scroll stays opt-in (11), menu completeness and synced key equivalents (21, 22), live column
changes (24), Liquid Glass visual review (15).

### W12. Metadata, Book Info, series navigation (T8, Phase 9, request 29)

Depends on W5 (real metadata observations). Identity is path only (D4, closed). Series are expected in the
same directory as the book.

- Extend `EPUBPackage` (today one `title` and one `creator`) with language, publisher, identifier, date,
  description, series, and source-specific fields (tags, rating, fandom, stats) only where samples show
  they exist. Check fixtures before assuming AO3 or fichub files carry series metadata.
- Book Info sheet. Store a text snippet with new bookmarks.
- Series folders (new feature, D16). Settings section where the user adds folders to look in, stored as
  security-scoped bookmarks (the app-scope entitlement exists; `HistoryManager` already does this for
  files). Needed because the sandbox grants only the opened file, not its directory. The current book's
  own folder is offered for granting the first time series navigation is used. Naming: "Series folders",
  not "Library". This is a metadata lookup for siblings, not a library view or cross-book text search.
- Series navigation (opt-in, off by default, offline): persisted identity (work ID, series IDs, part index,
  neighbors) from reliable metadata or source URL, no title guessing. Candidates come from the current
  folder first, then the added folders. Chooser for zero, multiple, or ambiguous matches (including the same
  work in several formats); never open silently; no network.
- Scan design (proposed): on demand, background queue, read only each candidate's package metadata, in
  memory cache keyed by folder and modification date, no on-disk index (UserDefaults-only invariant).
  Revisit if folders are very large. Single-entry archive read in ZIPFoundation 0.9.20 is unverified.
- Calibre-converted files rename classes, so template detection should prefer metadata and structure over
  class names where samples allow. Hypothesis until samples are inspected.

### W13. Polish and deferred (Phase 7, Phase 6, requests 5, 14, 20, 25)

Icon exploration and small-size review (artwork independent of reader code); Settings follow-ups
(Appearance refresh after Reset All, swatch accessibility, system spacing); Nectar theme review without
porting its theme system. Deferred: HTML and TXT (Phase 6), highlights and notes, reading reminders
and statistics, localization.

### W14. Source-style preface (new, optional, D12 and D13)

Goal: an optional setting that makes the start of a book look like the source site's work header
(AO3 first, other sites later). Off by default, where a book looks like a normal EPUB in Honeycrisp's
reader styling. Global setting, not per book. This is Honeycrisp-authored styling, not the book's CSS.

Reference: Ambrosia's theming plan. Reuse its rules, not its bundle system: colors stay owned by the user's
theme; the preface style may set typography and decoration only; accents are derived from the theme (for
example its link color) and checked for contrast; no network, no web fonts, system fonts only; any CSS
text must pass the sanitizer (W2.5). Not ported: theme bundles, `tokens.json`, importable themes
(Honeycrisp already has in-app editable themes).

Approach options (D12):
- A (recommended first). Restyle the EPUB's own preface in place when a template is recognized, using
  scoped CSS keyed on markup observed in samples. Adds no text, so character offsets, search, and saved
  positions are unaffected. Hook point: the existing first-spine-item handling (`stripPrefaceHeading`).
- B (later). Synthesize a preface from parsed metadata when the book has none. Adds text nodes, so it
  must be excluded from offset counting or tied to the layout-version rule (W1.3), with an offset test
  before shipping. All metadata text must be HTML-escaped; summaries are untrusted.
- Both go through the shared `extractedChapterBody` so scroll and paginated modes cannot drift.

Prerequisites: samples inspected (W5) for real markers; W2.5; non-goal wording agreed (D13).
Tests: template detection on synthetic fixtures modeled on structure, generic fallback leaves output
unchanged, offsets identical with the setting on and off (approach A), contrast check for derived accents
in every built-in theme.

Parked, not requested: keeping a safe allowlist of author inline formatting (Ambrosia plan Phase 6). Revisit
only if samples show centered dividers or alignment are being lost.

## 4. Suggested sequence

| Step | Work | Depends on |
|---|---|---|
| 1 | W0, W1.1 to W1.3, W2.1, W2.2, W3.1; W2.5 and W2.6 if D14 approved | none |
| 2 | W3.2 | step 1 |
| 3 | W4 (navigation history; needs D10) | step 2 |
| 4 | W5 (owner, in parallel from step 1), W11 audit | none |
| 5 | W10.1 to W10.2 | W3.2 |
| 6 | W10.3 and W10.4 (W10.3 needs D11) | step 5 |
| 7 | W6.1, W6.2; PDF corpus and D6 | step 3 |
| 8 | W12 with series folders (D16), then W14 approach A (D12, D13); W7 if gates pass (D9) | W5, W6 |
| 9 | W9 (reduced, docs only) | none |
| 10 | W13 | any |
| Deferred or shelved | W2.3 (D2), W8 Quick Look (D8), Sparkle | revisit on request |

## 5. Docs to update alongside the work

`ARCHITECTURE.md` (anchor layout rule, navigation history, extension target, isolation model);
`INDEX.md` (new files, section maps, new base commit); `docs/reference-survey.md` (append T findings);
`CLAUDE.md` (soften or confirm the script-restriction invariant per D2; record decisions).
License handling: reimplement from described behavior for bookokrat, lue, baca, epy, KindleUnpack, hygg
(terms not reviewed). MIT sources (Varq, Octavo, Winston) need copyright notices when ported. AGPL
sources (readest, tomo) are study-only.

## 6. Verify before coding (not confirmed in this review)

`AVSpeechSynthesizerDelegate` range callback and macOS 13 behavior; PDFKit text and line-selection APIs;
`QLPreviewReply` content types and minimum macOS; XcodeGen `app-extension` embedding syntax; ZIPFoundation
0.9.20 traversal protection and single-entry read API; WebKit content-world and content-rule-list API
availability on macOS 13; effect of `com.apple.ibooks.epub` on Finder routing; App Group availability
under ad-hoc signing; whether entitlements survive the release workflow; `libmobi-swift` macOS build.

## 7. Rejected or out of scope (carried over)

Readium Swift Toolkit (iOS and UIKit), EPUBKit as a dependency, FlyingFox, swift-azw3, Markdown packages,
`epub-reader-light`, gorae, hygg sync and AI voices, pdfgrep, reading statistics, translation, cloud
voices, Tomo code reuse (AGPL).

## 8. Crosswalk

| Source ID | Unified |
|---|---|
| Phase 0, Phase 1 | W5 |
| Phase 2 | W6.1 |
| Phase 3 | W7 |
| Phase 4 | W6.2 |
| Phase 5 | W6.3 |
| Phase 6, 7 | W13 |
| Phase 8 | W8 |
| Phase 9 | W12 |
| F1, F2, F3, F9 | W2 |
| F4 | W9 |
| F5, T7, T1, A1 to A4, T11 | W1 |
| F6 | W6 |
| F7, T10 | W7 |
| F8, T4, T5, D1 to D4 (survey plan) | W10 (T4 also W3.2) |
| F10, T6, QL0 to QL6 | W8 |
| T2, B1, B2 | W3 |
| T3, C1 to C3 | W4 |
| T8 | W12 |
| T9 | W6.4 |
| Requests 1, 8 to 11, 15, 21, 22, 24 | W11 |
| Requests 2, 3 | W6 |
| Requests 5, 14, 20, 25 | W13 |
| Requests 6, 7, 26 | W5 |
| Requests 12, 23 | W10 |
| Requests 13, 19 (library part) | out of scope |
| Requests 19, 27 (Quick Look) | W8 |
| Request 28 | repository hygiene, done in `.gitignore` |
| Request 29 | W12 |
| Ambrosia plan Phase 1 | W2.5 |
| Ambrosia plan Phase 2 | W2.6, W3.3 |
| Ambrosia plan Phase 3 | W2.3 (not directly portable) |
| Ambrosia plan Phase 4 | not ported; W14 reuses its color and CSS rules only |
| Ambrosia plan Phase 5 | W3.4 |
| Ambrosia plan Phase 6 | parked (see W14) |
| Ambrosia plan Phase 7 | not applicable |

## 9. Decisions needed from the owner

| ID | Decision | Status |
|---|---|---|
| D1 | Decouple W1 to W4 from the Phase 0 gate | Decided: yes |
| D2 | Content isolation timing | Decided: later (W2.3 deferred) |
| D3 | Empty or font-only `encryption.xml` | Decided: accept suggestion; readable unless a real DRM marker is present |
| D4 | File identity for moved files | Decided: path only; W1.4 closed |
| D5 | Search-hit contrast target | Recommendation revised: 4.5 for text over hits; no numeric hit-to-page target (yellow on a light page measures about 1.2, so 3.0 is unattainable); keep the active hit visibly distinct. Awaiting confirmation |
| D6 | PDF reflow: no, yes, or after Phase 4 with samples | Open (needed at W6.4) |
| D7 | Quick Look stage and handler rank | Moot while W8 is shelved |
| D8 | Developer ID | Decided: none. Sparkle skipped, Quick Look shelved or moved to its own repo, release stays ad-hoc |
| D9 | Static LGPL linking via `libmobi-swift` | Open (needed at W7) |
| D10 | Navigation history (Back and Forward) as a new feature, with placement | Open (needed before W4) |
| D11 | Word-level speech highlighting, off by default | Open (needed at W10.3) |
| D12 | Preface approach: A restyle in place, B synthesize from metadata, or both (A first recommended) | Open (W14) |
| D13 | Edit non-goal wording in `CLAUDE.md`, README, roadmap: "no publisher CSS from the book; an optional Honeycrisp-authored source-style preface is allowed" | Open (W14) |
| D14 | Approve W2.5 (CSS value sanitizer) and W2.6 (strip body scripts and handlers) as security work | Open |
| D15 | Policy for inline `style=` and body `<style>` in chapters: leave, or strip to match "we strip styling" | Open, needs samples |
| D16 | Approve "Series folders" as a new Settings feature (security-scoped folder bookmarks, in-memory scan) and its placement | Open (W12) |
| D17 | DRM rule: real markers plus any encrypted resource using a non-font-obfuscation algorithm (superset of Readium's LCP and ADEPT markers) | Open (PR4) |
| D18 | History cap of 100 drops saved positions of older books: raise cap, separate bounded store, or leave | Open |
| D19 | Normalize paths in history lookups like bookmarks do (still path-only) | Open, optional |
| D20 | ZIP entry-count and size limits (traversal already handled by ZIPFoundation 0.9.20) | Recommendation: skip |
