# Honeycrisp roadmap

This is the only plan document. It replaces `roadmap-unified.md`, `implementation-roadmap.md`,
`implementation-plan-tranche-1.md`, `terminal-readers-survey-and-plan.md`,
`theme-and-typography-plan.md`, `reference-survey.md` and `honeycrisp-settings-window-plan.md`.
Design rules and contracts live in `docs/FRAMEWORK.md`; this file covers decisions, order and gates.

Status: active implementation. Local macOS build and tests are available; milestones below reflect
the current working tree and remain uncommitted. Items marked "verify" are unchecked.

## 1. Baseline

Present in code (read, not run):
- Durable storage: per-element decode, `StorageQuarantine`, `anchorLayout` on history and bookmarks.
- DRM detection limited to real markers (LCP, ADEPT, non-font encryption algorithms).
- `ReaderCSSSanitizer` on values interpolated into CSS; `ReaderContrast` search-hit palette.
- Editable themes with light and dark sets, five Settings tabs, hide images, skip cover, AO3
  formatting, remove-indents, scroll and paginated modes, history, bookmarks, search, speech (basic).
- 16 parser tests, plus tests for history, bookmarks, TOC, sanitizer, contrast, restore position.

Uncommitted work in the tree (changes to `EPUBParser`, `PaginationEngine`, `ReaderViewController`,
`ReaderWindowController`, `SettingsManager`, `SettingsWindowController`, `ThemePopoverViewController`,
plus `ReaderStyleTests` and `SettingsManagerThemeTests`). Its keep or drop split is decided in M0.

Known gaps in code today:
- `anchorLayout` is stored but never read, so a layout change restores offsets blindly.
- Chapter bodies keep `<script>`, event attributes and `javascript:` hrefs; `allowsContentJavaScript`
  is `true`; resource URLs are rewritten by regex (single-quoted, unquoted and `%20` cases fail).
- The merged scroll document concatenates every chapter, so book class names collide and cost grows
  with book size.
- Offsets are defined in JS and recomputed in Swift with no parity test.

## 2. Decisions

Resolved here as recommendations; reverse any by editing this table and the affected milestone.

| ID | Decision | Reason |
|---|---|---|
| R1 | Keep the book's own styles; override only the properties the user owns (FRAMEWORK C4). The old "no publisher CSS" non-goal is removed. | Stripping loses meaning (class-only italics and bold, verse alignment). Two references that keep publisher CSS (Varq, Rede) reached the same design. Subsumes old D13 and D15. |
| R2 | Chapters become separate documents inside one `WKWebView`, mounted as a window (FRAMEWORK C5). Construction (iframe per chapter) is confirmed by spike M3, not assumed. | Keeping book CSS requires isolation per chapter. The same structure gives continuous scroll without loading the whole book. |
| R3 | Resources are served by a scheme handler, from the unpacked folder first. Lazy zip reads with an entry cache come later if needed. | Removes `rewriteResourceURLs`, gives path containment, MIME control, and the place to inject style and `lang`. About 40 to 60 lines in the references. |
| R4 | Build continuous scroll ourselves. Do not adopt foliate-js, Readium, MuPDF or EPUBKit. | None of the references provide continuous scroll across chapters in a DOM reader; foliate-js replaces the position, pagination and search code. |
| R5 | SwiftSoup (MIT; pin an exact version after verifying it builds under this project) replaces regex handling of body, style, URLs and active content. Foundation `XMLDocument` stays for OPF and TOC. No Kanna, AEXML, Fuzi. | Regex is the source of the confirmed URL and tag bugs. Gated by the offset parity test (C2). |
| R6 | Two surface kinds: flowing (WebKit) and paged (PDFKit, images). Normalize flowing formats to chapters; do not force PDF or CBZ into chapters. | Matches how each format is actually read; keeps capabilities honest (C9). |
| R7 | Formats, in order: Markdown and plain text, PDF, CBZ, MOBI/AZW3. | Cost and dependency order. |
| R8 | PDF reflow: no. | Different product; PDFKit search and selection cover the need. Closes old D6. |
| R9 | MOBI/AZW3 via libmobi-swift converting to a temporary EPUB, only if it builds for macOS. Otherwise unsupported with a documented external conversion. No hand-written MOBI reader. Licensing is not a gate. | Only viable reading route found; a 100-line reader lacks images, navigation and KF8. |
| R10 | Content isolation (author JS off, app scripts in their own world) is part of M3, not deferred. Closes old D2 and D14. | The scheme handler and chapter host make it cheap now; before them it was expensive. |
| R11 | Continuous scroll position is `(resource, offset)`; progress is derived (C1). Paginated mode paginates per chapter; the displayed page count becomes per chapter or an estimate. This is a visible behavior change, to be confirmed in M4. | Global page numbers depend on laying out the whole book. |
| R12 | History retains more entries than it displays (start at 300, measure `UserDefaults` size first); path normalization like bookmarks. Closes old D18 and D19. | The cap of 100 silently drops saved positions. |
| R13 | Navigation history (Back and Forward): yes, as a pure type plus Go-menu items and rebindable shortcuts; toolbar button optional. Closes old D10. | Cheap, testable, high value for footnotes. |
| R14 | Word-level speech highlighting: yes, off by default, after the chapter host exists. Closes old D11. | Needs offset-to-range mapping in the mounted window. |
| R15 | Parked: source-style preface (old W14), Series folders and series navigation (old D16), Quick Look (old W8), Sparkle, notarization. | R1 makes the preface mostly unnecessary; the rest need a Developer ID or add sandbox and library-like scope. Revisit on request. |
| R16 | Deployment floor stays macOS 13 for now. Liquid Glass is a later chrome milestone (M10) behind `#available`, written only when it can be tested on macOS 26. Rede is the model. | The reviewer's machine is on macOS 15, so macOS 26 code cannot be tested yet. |
| R17 | ZIP entry-count and size limits: skip. DRM rule and search-hit contrast: already implemented. Closes old D17, D20, D5. | Containment is handled by ZIPFoundation; the rest is done. |
| R18 | Platform chrome work (M8) is independent of the reader pipeline (M3 to M6) and may run in parallel. | No shared files except `ReaderViewController`; coordinate there. |

## 3. Milestones

Effort: S under a day, M a few days, L a week or more. Each item is one PR with focused tests. A
milestone is done when its exit criteria hold and the affected docs are updated.

### M0. Baseline and truth (S)

Status: in progress (keep/drop decision and listed cleanup applied; local build and tests pass; the
keep set still needs its separate commit).

- Review the uncommitted diff file by file. Keep: code-font toggle, theme and popover work, new
  theme tests. Drop: `strippingEmbeddedStyles`, its tests, and the `currentLayout` bump to 2 (R1).
  Commit the keep set separately.
- `CLAUDE.md` rewritten to match this plan and `INDEX.md` regenerated from the current tree (done,
  with the helper scripts `scripts/index-anchors.sh` and `scripts/make-diff.sh`). Docs map added to
  the README.
- Delete the stale duplicate `swiftlint.yml` (292 bytes, no dot); `.swiftlint.yml` is the config in use.
- Fix the Settings tab count and the README architecture table.
- Add a one-line note in `ARCHITECTURE.md` that script and URL restrictions are not enforced until M3.

Exit: tree builds, `./test.sh` passes locally, docs list one plan and one design.

### M1. Safety net and contracts (M)

Status: complete (Locator, fraction fallback, and progress derivation are implemented; synthetic
WebKit parity and regression fixtures pass with expected failures for the currently known defects).

- Define `Locator` (C1) as a pure type with the fraction fallback; store `fraction` with new records
  (defaulting decode); make restore read `anchorLayout`. Tests for match, mismatch and missing fields.
- Build the WebKit test harness (C2, C4): load synthetic chapters in a `WKWebView` inside XCTest.
  First test: offset parity on entities, supplementary Unicode, whitespace, `<a id="x"/>`.
- Fixtures for confirmed bugs: nested `Text/Images` layout, `%20` and single-quoted attributes,
  `#fragment` and cross-chapter links, self-closed anchors, class-only italics, centered verse.
- Progress derivation (C1) as a pure function with tests.

Exit: all fixtures exist and the known bugs are reproduced by failing or expected-fail tests.

Harness finding: the first live-DOM parity fixture currently reports a three UTF-16-unit offset
shift from whitespace in the merged-document wrapper. This is an expected failure in M1 and must be
resolved before the M3 host can adopt the parity contract.

### M2. Typography and themes (M, parallel track, independent of M3 to M6)

Status: complete (alignment, language-aware hyphenation, paragraph spacing and optional first-line
indent, bold weight, versioned theme transfer, and non-blocking contrast warnings are implemented;
theme file access uses the selected security-scoped URL; local test script passes).

Order: text alignment and hyphenation per theme (`Theme.textAlign`, `Theme.hyphenate`, vars, reset,
customized check, tests); `EPUBPackage.language` from `dc:language`, sanitized to BCP 47, emitted as
`<html lang>`; `hyphens` plus `-webkit-hyphens` (verify which prefix macOS 13 WebKit honors);
bold text and paragraph spacing; controls in Appearance; theme JSON import and export (version 1,
per-field fallback through the sanitizer, new UUID, never overwrite seeds); contrast warning using
`ReaderContrast.ratio`, warn and do not block. Optional alignment and hyphenation use the low
specificity mechanism in C4. Under R1, the old "font override gaps" (inline font face, SVG text)
are handled by the user layer, not by stripping.

Exit: settings round-trip, existing stored themes still decode, hyphenation does nothing safely when
the language is unknown (help text "Needs book language").

### M3. Spike: chapter host, scheme handler, user layer (L, behind a flag)

Status: in progress (a contained EPUB resource scheme handler and MIME mapping are implemented and
unit covered; production chapter hosting, wrapper/style injection, and JavaScript isolation remain).

Build for one chapter, then a window of three, in the existing book window. Components: scheme
handler (path containment, MIME from manifest, style and `lang` injection), chapter document per
resource served as XML where XHTML, cascade layers (C4), author JS off with app scripts in their own
world (verify API), content isolation checks.

Exit criteria, all measured:
- class-only italics and bold survive; user font, size, color and line height win.
- relative images resolve in nested `Text/Images` layouts with no string rewriting.
- self-closed anchors do not swallow content.
- cosmetic changes patch all mounted chapters without reload.
- position restore by `(resource, offset)` matches the parity test.
- a synthetic 2,000-page book opens within a budget and memory stays under a budget; set both
  numbers from a baseline measurement of the current reader first, then record them here.
- author scripts do not execute (positive-control test proves the old behavior was observable).

Outcome recorded as a decision: adopt, or fall back to a sanitized merged document with
per-chapter style scoping.

### M4. Windowed continuous scroll and per-chapter pagination (L)

Status: not started.

Mount and evict neighbors near the edges; prepend without visual jump; measure memory. Paginated
mode paginates inside each chapter with a pager hand-off at chapter edges (R11). Update
`scrollRestoreBootstrapJS` and offset restore for the window model.

Exit: scroll across 20 chapter boundaries without jump; paginated forward and back across chapters
restores exact positions; memory within the M3 budget.

### M5. Port features, delete the merge pipeline (L)

Status: not started.

Port onto the host, one per PR: position save and restore, search and highlights, auto-scroll,
speech, bookmarks, TOC jumps, in-book links including cross-chapter links. Add navigation history
(R13). Then delete `buildScrollHTML` merging, `rewriteResourceURLs` and the regex URL code. Split
`EPUBParser.swift` by layer at this point (FRAMEWORK section 2).

Exit: parity and restore tests green; no reference to the removed functions; INDEX and ARCHITECTURE
updated.

### M6. Content pipeline on SwiftSoup (M)

Status: not started.

Move body extraction, active-content removal, AO3 formatting, indent stripping and text extraction to
SwiftSoup. Verify the package builds under the project's settings first. Gate: parity test (C2)
passes on every fixture; `layout` version bumped once, with the fraction fallback tested.

Exit: no regex remains in L2 for HTML structure; chapter bodies contain no `<script>`, `on*` or
`javascript:`.

### M7. Formats (M each, after M5)

Status: not started.

1. Markdown and plain text: convert to chapters at L0. Plain text is escaping plus paragraph
   detection; Markdown splits chapters on top-level headings. Verify the Markdown parser choice from
   its manifest and docs before adding it (candidates: Foundation Markdown support, or a small
   package); none is assumed. Supported-types registry shared by Open panel, drag-and-drop, Finder
   events and Open Recent, with content validation.
2. PDF: PDFKit view as `PagedSurface`, `Locator.page`, native outline, PDFKit search, capabilities
   exclude themes and speech. Format-discriminated persistence audit lands here (C7).
3. CBZ: ZIPFoundation plus an image page view. Natural sort of entries; paged capabilities.
4. MOBI/AZW3: gate on a macOS build of libmobi-swift (its manifest declares iOS only; verify), then
   temporary EPUB conversion with reliable cleanup and history keyed to the original path.

Exit per format: open, restore, history, bookmarks, error mapping, and tests with generated fixtures.

### M8. Chrome (M, parallel track)

Status: not started.

Model: Rede's UI, adapted to AppKit and macOS 13. Items in priority order:
1. Native title and subtitle in the toolbar; chapter breadcrumb as the title.
2. One combined "Aa" popover: font size, font, line and paragraph spacing, appearance (system,
   light, dark), two quick swatches, reset that disables at defaults. Full theme editor stays in
   Settings.
3. Settings theme editor: pin the preview above the scroll area; "Preview as Light/Dark" toggle;
   coalesce color-well writes.
4. Decide: overlay Contents drawer versus the existing sidebar; small page caption.
5. Dark and light follow the system by default (the setting exists); verify every surface.
All chrome reads from the chrome tokens (C10).

Exit: no hardcoded materials or bar colors outside the chrome definitions.

### M9. Reader features (M each, after M5)

Status: not started.

- Speech: one extractor for all chapters with block separators (not shared with search offsets),
  sentence chunking with abbreviation protection, each chunk carrying a `Locator`; word highlight
  from synthesizer range callbacks, off by default (verify the callback and its macOS 13 behavior);
  explicit state machine for start, stop and finish races.
- Book Info sheet from parsed metadata (publisher, language, identifier, date, description);
  store a text snippet with new bookmarks.
- Audit of input and menu requests (full-window drop target, media keys where macOS exposes them,
  auto-scroll hold-to-change, menu completeness, live column changes): mark done, partial, open.

### M10. Platform generation (later)

Status: not started.

Liquid Glass chrome for macOS 26 behind `#available`, written when it can be run and checked on
macOS 26, following Rede. Raise the deployment floor only if a feature requires it. Icon review for
the new platform style.

### Continuous

- Compatibility corpus: record observed outcome per sample class in
  `docs/compatibility-corpus.md`; fix general issues before source-specific ones.
- KEPUB: handle only markers actually observed.
- Settings polish: refresh Appearance after Reset All, swatch accessibility, system spacing.
- Docs updated with each milestone; deletion of anything superseded.

## 4. Order

```
M0 -> M1 -> M3 -> M4 -> M5 -> M6 -> M7 (1, 2, 3, 4) -> M9
        \-> M2 (parallel, after M0)
        \-> M8 (parallel, after M0)   M10 later
```

M1 gates M3 (the harness is how the spike is judged). M3's outcome gates M4 to M6. M2 and M8 touch
settings and chrome, not the pipeline, so they can fill gaps.

## 5. Not planned

Library view, cross-book search, quote sharing, translation, cloud or AI voices, sync, export,
statistics, per-book reading mode, PDF reflow, Quick Look, Sparkle and notarization, series
navigation, source-style preface, hand-written MOBI reader, Readium, foliate-js, MuPDF, EPUBKit,
Kanna, AEXML, Fuzi, SWCompression. Reasons are in section 2 and in the references surveyed; each can
be reopened by editing this file.

## 6. Verify before coding

- WebKit: author-JS-off semantics with client-world scripts and user scripts on macOS 13;
  `WKURLSchemeHandler` response headers (Content-Security-Policy honored or not); whether
  `ENABLE_OUTGOING_NETWORK_CONNECTIONS` can be dropped once content cannot reach the network.
- Hyphenation prefix honored by macOS 13 WebKit; that low-specificity alignment rules lose to book
  class and inline rules.
- SwiftSoup: builds under `SWIFT_VERSION: 5.9` and project settings; behavior on real XHTML.
- Markdown parser choice and its API; libmobi-swift macOS build.
- ZIPFoundation single-entry read API (needed only for lazy zip serving).
- `AVSpeechSynthesizerDelegate` range callback on macOS 13.
- Which of `NSToolbar` title and subtitle APIs are available at the deployment floor.
- Whether the uncommitted diff contains anything beyond what the plan documents describe; it was
  listed by file, not audited line by line.

## 6a. Old identifiers

| Old | Now |
|---|---|
| W0 | M0 |
| W1, W2.1, W2.2, W2.5, W3.1 | done in code (baseline) |
| W2.3, W2.4, W2.6 | M3 (R3, R10), M6 |
| W3.2, W10 | M9 |
| W4 | M5 (R13) |
| W5 | Continuous (corpus) |
| W6, Phases 2, 4, 5 | M7 |
| W7 | M7.4 (R9) |
| W8 | parked (R15) |
| W9 | unchanged: tag-driven ad-hoc releases, Homebrew as the update path |
| W11 | M9 audit, M8 |
| W12 | M9 Book Info; series parked |
| W13 | Continuous, M10 |
| W14 | parked (R1, R15) |
| Theme plan sections 1, 3 | M2 |
| Theme plan section 2 | superseded by R1 |
| D1 to D4 | decided earlier; unchanged |
| D5, D17, D20 | R17 |
| D6 | R8 |
| D9 | R9 |
| D2, D14 | R10 |
| D10, D11 | R13, R14 |
| D12, D13, D15, D16 | R1, R15 |
| D18, D19 | R12 |
