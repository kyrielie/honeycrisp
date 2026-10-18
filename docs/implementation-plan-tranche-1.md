# Honeycrisp implementation plan, tranche 1 (DRAFT, pending approval)

Base: `b4ab619` plus the uncommitted `.gitignore` and `make_upload_zip.sh` edits. Companion to
`roadmap-unified.md` (workstream IDs W0 to W14, decisions D1 to D16). All code below is a sketch: not
compiled, not run. No macOS toolchain is available in this review environment, so every PR needs
`./test.sh` and the lint command run locally before merge.

## 1. What to implement first, and why

Order is chosen by: no dependency on samples, real data-loss or correctness risk, small blast radius,
and testable with the existing synthetic-fixture pattern.

| Order | PR | Workstream | Gate | Why this position |
|---|---|---|---|---|
| 1 | PR0 | W0 docs truth | your OK to replace docs | Removes drift that misleads every later change |
| 2 | PR1 | W1.1 bookmark durability | none (D1) | Confirmed data loss path, no UI, pure logic |
| 3 | PR2 | W1.2 history durability | none (D1) | Same defect, and history holds saved positions |
| 4 | PR3 | W1.3 anchor layout field | none (D1) | Touches the same decode paths; do before any extraction change |
| 5 | PR4 | W2.1 DRM precision | D3 accepted, D17 | Small, user-visible, testable |
| 6 | PR5 | W3.1 search-hit contrast | D5 confirmation | Visible bug, touches `readerVarsCSS` |
| 7 | PR6 | W2.5 CSS value sanitizer | D14 | Prerequisite for any preface or derived colors |
| 8 | PR7 | W2.6 body active content | D14 | Partial security mitigation, no visible change |

PR1 to PR3 are the recommended first work: they are ungated, protect user data, and are independent of
every open decision. Everything after PR3 waits only on the decisions named.

W2.2 (archive traversal) is closed by verification, see section 2.

## 2. Verified in this round

| Claim | Evidence |
|---|---|
| `BookmarkManager.init` resets to empty and the next save overwrites | `ReadingBookmark.swift` init: `try? decode(Envelope)` and `envelope.version == 1`, else `bookmarks = []`; `save()` always writes |
| `HistoryManager.load` resets to empty and the next save overwrites | `HistoryManager.swift` `load()`: `try? decode([HistoryEntry].self)` else return with `entries = []`; `record` calls `save()` |
| History is capped at 100 entries and positions live in the entries | `maxEntries: Int = 100`; `record` truncates with `prefix(maxEntries)`. Reading position for the 101st most recent book is deleted. Relevant to a large fanfiction library. See D18 |
| History and bookmarks compare paths differently | History uses `$0.url == url`; bookmarks use `ReadingBookmark.normalizedPath` (standardized, symlinks resolved). Same file reached by two path forms can duplicate history entries. See D19 |
| ZIPFoundation 0.9.20 rejects path traversal | `FileManager+ZIP.swift` `unzipItem`: `guard entryURL.isContained(in: destinationURL)` else throws; `allowUncontainedSymlinks` defaults to false; CRC32 verified by default. No entry-count or size limits exist. Resolved version confirmed in `Package.resolved` |
| Single-entry reads exist in ZIPFoundation 0.9.20 | `Archive(url:accessMode:pathEncoding:)`, `subscript(path:) -> Entry?`, `extract(_:bufferSize:skipCRC32:progress:consumer:)` (`Archive.swift`, `Archive+Reading.swift`) |
| Readium DRM markers | `EPUBFormatSniffer.swift` `sniffDRM`: LCP if `META-INF/license.lcpl` exists, or a `RetrievalMethod` URI equal to `license.lcpl#/encryption/content_key` under `EncryptedData/KeyInfo`; ADEPT if a `resource` element exists under `EncryptedData/KeyInfo` |
| Font obfuscation algorithm ids | `EPUBDeobfuscator.swift`: `http://www.idpf.org/2008/embedding` and `http://ns.adobe.com/pdf/enc#RC` |
| Contrast numbers (computed, WCAG relative luminance) | `#E5E5EA` text on the current `#FFEE58` hit: 1.05. White: 1.19. `#1A1A1A`: 14.61. Black: 17.62. Hit versus page: 1.17 on `#FFFDF6`, 1.19 on white |

Not verified: Readium's `XMLNamespace` URIs (that file path returned no content), so PR4 matches by
element local name instead of namespace.

### Correction to my D5 recommendation

I previously recommended 3.0 between a hit and the page. That is not achievable for a yellow marker on a
light page (1.17 to 1.19 measured above) and is not how highlighters work. Revised D5 recommendation:
4.5 for text over a hit, nothing numeric for hit versus page, and keep the active hit visibly distinct
from other hits (outline or stronger fill). Please confirm or choose otherwise.

## 3. PR0: documentation truth (W0)

Gate: your approval to replace and edit docs.

- Add `docs/roadmap.md` from `roadmap-unified.md`; add a "superseded by docs/roadmap.md" line at the top of
  `docs/implementation-roadmap.md` and `docs/terminal-readers-survey-and-plan.md` (keep them for history).
- `ARCHITECTURE.md`, `README.md`, `docs/honeycrisp-settings-window-plan.md`: Settings tabs are five (General,
  Reading, Appearance, History, Shortcuts per `INDEX.md`).
- `docs/implementation-roadmap.md` requests 16 and 17: "Completed in Phase 3" is a stale phase number.
- `INDEX.md`: base commit `b4ab619`; refresh `// MARK:` ranges with grep.
- `CLAUDE.md` (needs your OK): one line that script and URL restrictions are not enforced yet (W2.3 deferred).
- README architecture table: add missing files (Sidebar, Settings, Parsing, History additions).

Acceptance: no code change; docs agree with `INDEX.md`.

## 4. PR1: bookmark durability (W1.1)

Files: `Sources/History/ReadingBookmark.swift`; tests in `Tests/HoneycrispTests/BookmarkManagerTests.swift`.

Current behavior: `BookmarkManager.init` (lines about 31 to 38) decodes `Envelope` with `try?` and requires
`version == 1`; any failure sets `bookmarks = []`; `private func save()` then overwrites storage.

Design:

1. A small internal helper `StorageQuarantine` (new file `Sources/History/StorageQuarantine.swift`, shared
   with PR2):
   - `static func preserve(_ raw: Data, key: String, defaults: UserDefaults, reason: String)` writes the raw
     bytes to `<key>.quarantine.<unix-seconds>` and prunes to the newest 3 copies (UserDefaults is not
     for bulk data, so keep this bounded).
   - Called once, before the first overwrite after a failed or partial load.
2. Decode per element. Parse with `JSONSerialization` into `version: Int` and `bookmarks: [Any]`. Re-serialize
   each element and `JSONDecoder().decode(ReadingBookmark.self, ...)`. Elements that decode become
   `bookmarks`; elements that fail are kept as raw `Data` in `private var unreadableElements: [Data]`.
3. Write back. `save()` encodes valid bookmarks, then appends the unreadable elements (parsed back with
   `JSONSerialization`) so they survive a round trip, and writes the envelope. Keep `Envelope.version` at 1
   for known data.
4. Newer version. If `version > 1`: still decode what can be decoded, set `needsQuarantineBeforeWrite = true`,
   and call `StorageQuarantine.preserve` with the original blob before the first save. Never silently
   discard.
5. Whole-blob corruption (not JSON): `bookmarks = []`, set the same flag, preserve before the first save.
   The existing test `testCorruptBookmarkDataDoesNotAffectHistoryPersistence` (expects an empty list from
   `"not-json"`) still passes.

Tests (in-memory `UserDefaults` suite, same `makeManager()` pattern):

- `testCorruptElementAmongValidOnesLoadsTheValidOnesAndSurvivesSave`
- `testNewerEnvelopeVersionIsPreservedBeforeOverwrite` (assert a `.quarantine.` key exists with the original bytes)
- `testWholeBlobCorruptionIsPreservedBeforeFirstSave`
- `testQuarantineKeepsOnlyNewestThreeCopies`
- Existing tests unchanged.

Risk: low. Date encoding uses the default strategy on both sides, so element round trips are stable
(confirm in the test by comparing `createdAt`). Untested areas touched: none beyond bookmark storage.
Acceptance: a bad element, a newer version, or a corrupt blob never deletes recoverable data.

## 5. PR2: history durability (W1.2)

Files: `Sources/History/HistoryManager.swift` (`load()` at the end of the file, `save()`); tests in
`HistoryManagerTests.swift`, `HistoryEntryTests.swift`.

- Same pattern as PR1 on the bare `[HistoryEntry]` array (no envelope exists; do not introduce one, to avoid
  a format migration). Per-element decode via `JSONSerialization` array; unreadable elements kept as raw
  `Data` and re-emitted on `save()`; whole-blob failure goes through `StorageQuarantine`.
- Keep `maxEntries` truncation applying to decoded plus unreadable elements together, or unreadable ones
  would grow unbounded. Decision: unreadable elements count toward the cap and are dropped oldest-first
  with the rest.
- `record` must keep carrying `readingProgressPercent`, `lastSpineIndex`, `lastCharacterOffset` forward
  (regression-tested by `testRecordMovesBookToFrontAndPreservesSavedProgressAndPosition`); do not touch that
  logic.
- D18 and D19 are separate optional PRs if approved: position retention beyond the 100 cap, and path
  normalization in `record`, `updateProgress`, `updatePosition`, `savedPosition`.

Tests: corrupt element among valid ones; unreadable survives save; whole-blob corruption preserved; cap
counts unreadable elements.
Risk: low to medium (every open calls `record`). Acceptance: one bad history entry never wipes history.

## 6. PR3: anchor layout field (W1.3)

Files: `ReadingBookmark.swift`, `HistoryManager.swift` (`HistoryEntry`), `ARCHITECTURE.md`; tests in
`HistoryEntryTests.swift`, `BookmarkManagerTests.swift`.

- Add `static let currentAnchorLayout = 1` in one place (suggest `Sources/Reader/PaginationEngine.swift`
  next to `RestorePosition`, which defines the position vocabulary).
- `HistoryEntry`: add `var anchorLayout: Int = EPUBAnchor.currentLayout`; the existing custom `init(from:)`
  gets `anchorLayout = try c.decodeIfPresent(Int.self, forKey: .anchorLayout) ?? 1`. `updatePosition` stamps
  the current value.
- `ReadingBookmark` currently uses synthesized `Codable`; adding a non-optional stored property would break
  decoding of old JSON. Add a custom `init(from:)` with `decodeIfPresent` (PR1's per-element decode makes
  this safe to ship).
- Consumers: none in this PR. Reading an old layout and choosing a fallback (fraction from
  `readingProgressPercent`) is added in the same PR that first changes extraction (for example W3.3). Say so
  in the PR; a stored but unread field is intentional insurance, not a feature.
- Rule for `ARCHITECTURE.md`: bump `currentAnchorLayout` whenever text extraction or chapter formatting
  changes character offsets (anything touching `extractedChapterBody`, `searchableText`, indent stripping,
  preface stripping, first-chapter formatting).

Tests: legacy JSON without the key decodes to 1 (extend `testLegacyHistoryDecodesWithDefaultRestorePosition`);
round trip preserves a non-default value; bookmark legacy JSON decodes.
Acceptance: old stored data decodes unchanged; new data carries the field.

## 7. PR4: DRM precision (W2.1, D3, D17)

Files: `Sources/Parsing/EPUBParser.swift` `parsePackage` (lines about 129 to 141); tests in
`EPUBParserTests.swift` (`testDRMErrorTakesPrecedenceOverMissingContainer`, line 146).

Current: throws `.drmProtected` if `META-INF/encryption.xml` exists, before reading `container.xml`.

Proposed rule (D17, a superset of Readium's markers): DRM if any of these hold:

1. `META-INF/license.lcpl` exists.
2. `encryption.xml` has an `EncryptedData/KeyInfo/RetrievalMethod` with `URI` equal to
   `license.lcpl#/encryption/content_key`, or an `EncryptedData/KeyInfo/resource` element (ADEPT).
3. `encryption.xml` has any `EncryptionMethod` whose `Algorithm` is not one of the two font-obfuscation ids
   (`http://www.idpf.org/2008/embedding`, `http://ns.adobe.com/pdf/enc#RC`). This catches unknown schemes
   that Readium's two markers would miss; it is my addition, not Readium's.

Not DRM: missing or empty `encryption.xml`, or one listing only font-obfuscation methods (D3).

Implementation notes:
- Parse with `XMLDocument` and `local-name()` XPath, the same style `parseOPF` already uses, so namespace
  URIs are never needed (they were not verified).
- Unparseable `encryption.xml`: treat as not DRM and continue; the OPF or spine failure then reports as it
  would for any broken book. State this in a comment.
- Keep the check before `container.xml` (as today), so a DRM book still gets the specific message.

Tests (synthetic roots via the existing `makeEPUBRoot` helper):
- Font-obfuscation-only `encryption.xml` plus a valid package opens normally.
- ADEPT `resource` element throws `.drmProtected`.
- LCP `license.lcpl` file throws `.drmProtected`.
- Unknown algorithm throws `.drmProtected`.
- Empty `<encryption/>`: rewrite `testDRMErrorTakesPrecedenceOverMissingContainer` so it uses an ADEPT marker
  (keeps the precedence assertion); add a new test that empty `<encryption/>` with no container yields the
  missing-container error, not DRM. The PR description states this expected-result change (D3).

Risk: low. Acceptance: no false DRM rejection for font-only books; real DRM still reports the specific error.

## 8. PR5: search-hit contrast (W3.1, D5)

Files: `Sources/Parsing/EPUBParser.swift` (`readerCSS`, `mark.ql-hit` at lines about 1070 to 1079;
`ReaderCosmeticSettings` and `readerVarsCSS` at lines about 60 to 90 and 1051); `Sources/Settings/SettingsManager.swift`
(`effectiveBackgroundCSS`, `effectiveTextCSS`, `effectiveLinkCSS` at lines 388 to 390; color helpers at
lines 749 to 768); the hit markup comes from `readerJS` (`mark.ql-hit` at lines about 671 and 717, untouched).

Why vars and not static CSS: `applyCosmeticCSSUpdate` (`ReaderViewController.swift` about line 1048) replaces
only `<style id="honeycrisp-vars">` with `readerVarsCSS`, so hit colors that depend on the theme must live
in `readerVarsCSS` to repaint on theme change without a reload.

Design:
1. New pure helper `ReaderContrast` (new file `Sources/Settings/ReaderContrast.swift`): relative luminance,
   `ratio(_:_:)`, and `hitColors(background:text:) -> (hitBackground, hitText, activeBackground, activeText)`.
   Parse inputs with the existing `SettingsManager.color(fromCSS:)` semantics (6-digit hex only, else black).
2. Selection: light page (luminance above a threshold) uses `#FFEE58` with black text (17.62:1). Dark page uses
   a deep amber (candidate `#7A5F00`, white text 6.06:1, computed above) with white text. Always set an explicit
   text color on hits, then verify the ratio is at least 4.5 and fall back to black on `#FFEE58` otherwise.
3. Active hit: today `background: Highlight; color: HighlightText` (system colors). Keep, but add a 2px outline
   in the explicit hit text color so it is distinct from other hits regardless of the user's accent color.
4. Add `hitBackground`, `hitText`, `hitActiveBackground`, `hitActiveText` to `ReaderCosmeticSettings`
   (populated in `current(from:)`), emit as `--reader-hit-*` in `readerVarsCSS`, and change `mark.ql-hit` rules to
   `background: var(--reader-hit-bg); color: var(--reader-hit-text);`.
5. Because `ReaderCosmeticSettings` is `Equatable` and passed explicitly, tests can construct it directly.

Tests: `ReaderContrastTests` (known pairs: black on white 21; computed values above), every seeded default theme
in light and dark yields text over hit of at least 4.5, `readerVarsCSS` output contains the four variables,
`readerCSS` no longer contains the literal `#FFEE58` inside the hit rule. Untested areas touched:
`SettingsManager` getters (read only), live patch path.
Risk: low to medium (touches the shared vars block both modes use). Acceptance: hits readable in every default theme.

## 9. PR6: CSS value sanitizer (W2.5, D14)

Files: new `Sources/Settings/ReaderCSSSanitizer.swift`; wire into `ReaderCosmeticSettings.current(from:)`
(`EPUBParser.swift` about line 76) so both initial render and the live patch get sanitized values.

- Reachable raw inputs (verified): `fontFamily` (`SettingsManager.fontFamily`, also set from the custom font store),
  `backgroundCSS`, `textCSS`, `linkCSS` from persisted `Theme` JSON, interpolated unvalidated in `readerVarsCSS`.
  The live patch already JSON-encodes the whole string for JS (`jsStringLiteral`), so the gap is CSS validity,
  not JS injection.
- Before coding: read how `effectiveColorSet` is built and what values `Theme` colors can hold (not read this round).
- Pure functions: `hexColor(_:fallback:)` (normalize 3 or 6 digit hex to `#RRGGBB`, reject others),
  `fontFamily(_:fallback:)` (accept quoted or bare family names with letters, digits, spaces, `._-`, length limit,
  or an exact known preset stack; reject braces, semicolons, angle brackets, backslashes, `url(`), and numeric
  clamps for the numeric vars (values already come from steppers; clamp as defense).
- Fallbacks are the current defaults; never emit a partially cleaned value.

Tests: pure type only (`SettingsManager` has no tests): valid hex normalized; injection strings
(`#fff;}body{`, `</style>`) fall back; known preset stacks round trip; quoted custom family accepted;
65 character family rejected.
Risk: low. Acceptance: no persisted value can break the stylesheet.

## 10. PR7: chapter body active content (W2.6, D14)

Files: `Sources/Parsing/EPUBParser.swift` `extractedChapterBody` (about line 553), `rewriteResourceURLs`
(about line 631).

Verified current state: `extractBody` keeps body content as is; nothing removes body `<script>`, `<style>`,
`style=`, `on*=` attributes or `javascript:` hrefs (`rewriteResourceURLs` returns `javascript:` values unchanged).

- Add one helper `stripActiveContent(_:)` applied in `extractedChapterBody` after `extractBody`, so scroll and
  paginated modes share it (the existing invariant that both modes use `extractedChapterBody`):
  - remove `<script ...>...</script>` (case-insensitive, dotall);
  - remove `on[a-z]+` attributes in double-quoted, single-quoted and unquoted forms, requiring whitespace before
    `on`, and test that `data-online="x"` is untouched (tighten to a known event-name list if the pattern fails);
  - rewrite `href`, `src`, `xlink:href` values starting with `javascript:` to `#`.
- Reader scripts are added outside the extracted body (`buildScrollHTML` and `buildPageHTML` templates), so they
  are unaffected.
- Inline `style=` and body `<style>` are NOT touched here (D15).
- This is a regex mitigation, not isolation; it does not replace W2.3.
- Offset effect (unverified, read first): `searchableText` strips `<script>` and `<style>` blocks before computing
  search offsets (`EPUBParser.swift` line 205), while saved positions use a text-node walk in the page JS. A DOM
  `TreeWalker(SHOW_TEXT)` does visit text inside script and style elements unless the walk filters them, so
  chapters with inline script or style could already disagree between the two. Read the walk in `readerJS`
  and `PaginationJS` before this PR. If it counts them, stripping body scripts aligns the two (and bumps
  `currentAnchorLayout`, PR3); if it filters them, no offset change. Add a fixture test with an inline script
  either way.

Tests: each removal case, `data-online` safe, `javascript:` rewritten, a clean chapter is byte-identical, offsets
unchanged. Untested areas touched: none in UI.
Risk: low. Acceptance: no executable content survives in chapter bodies by these three routes.

## 11. Optional, needs separate approval

- D18: history keeps at most 100 entries (`HistoryManager.maxEntries`), so older books lose saved positions. Options:
  raise the cap; keep positions in a separate bounded store; leave as is. Not an identity change, so it does not
  reopen D4.
- D19: normalize paths in history lookups the way bookmarks do. Small, consistent, still path-only (D4 intact).
- D20: ZIP entry-count and size limits. Traversal is already handled by ZIPFoundation, so this is only about
  decompression bombs; low risk for this audience. Recommendation: skip.

## 12. Working rules per PR

- One PR per row in section 1. Add `.swift` files, then `xcodegen generate`; never commit `Honeycrisp.xcodeproj`.
- Run `./test.sh`, then `xcrun swift-format lint --configuration .swift-format --recursive Sources Tests`
  limited to touched files; format only touched files.
- State in each PR which untested areas it touches (`SettingsManager`, `KeyBinding`, `PaginationEngine`,
  `ReaderViewController`, search UI).
- Update `INDEX.md` for new files and `ARCHITECTURE.md` for the anchor-layout rule. No claim that a build or
  test passed unless it was run.

## 13. After tranche 1 (summary)

Tranche 2: W4 navigation history (D10), W5 sample inspection (needs your samples), W12 metadata and Series
folders (D16), W14 preface approach A (D12, D13), speech groundwork W3.2 and W10.1 to W10.2. Then format work
(W6, W7) and polish. Details are in `roadmap-unified.md`.

## 14. Other repositories

Needed for tranche 1: none. I read Readium's sniffer and deobfuscator and ZIPFoundation 0.9.20 directly from
GitHub. Nectar and Ambrosia are reachable here as public repos (downloaded as archives; Nectar has an `AO3Kit`
module that W12 will want, not read yet), so no repomix is required for them. Repos I cannot locate without a
URL or an export: Varq, Octavo, Winston, `libmobi-swift` (needed only for W2.3, W6, W7, W8 later).
