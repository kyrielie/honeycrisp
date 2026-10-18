# Honeycrisp Implementation Roadmap

Status: Honeycrisp currently has an EPUB-only reader. EPUB parsing and reader
features have substantial implementation and synthetic test coverage, but the
real-file compatibility matrix has not been validated. The hide-images and
explicit-cover preferences from request 26 are implemented. PDF, MOBI/AZW3,
format dispatch, Quick Look, and AO3 series navigation remain unimplemented.
Keep `samples/` local and untracked; record format outcomes without copying
book content into the repository. Phase 0's source/license and device review is
the next gated activity; Phase 1 compatibility work remains pending that
review.

Honeycrisp remains a native macOS reader for local files. It is not a library
manager, ebook converter, or device-sync application. Add formats only where
the macOS platform provides a maintainable reader or a focused parser can feed
the existing reading surface.

## Format decisions

1. **EPUB and KEPUB are the primary reading formats.** KEPUB uses an EPUB
container and should be handled as EPUB with compatibility fixes, not a second
reader. Keep the current WebKit renderer and improve its parser only where
sample-driven evidence justifies it.
2. **Add PDF as a native macOS format using PDFKit.** PDF is a distinct fixed
page document, so keep page navigation and restoration format-specific.
Do not force it into EPUB spine or HTML abstractions.
3. **Evaluate MOBI and AZW3 import through `libmobi-swift`, with EPUB export as
the preferred bridge.** The local wrapper claims AZW, AZW3, AZW4, and MOBI
support, exposes raw HTML and metadata, and can create EPUB files. Its package
manifest declares iOS only, despite its README claiming macOS support. Do not
make it a production dependency until it builds for Honeycrisp's macOS target,
passes the local MOBI and both AZW3 samples, and its memory/error behavior has
been reviewed. If integration is viable, create a temporary EPUB or a
normalized in-memory EPUB source and route it through the existing EPUB
pipeline. Prefer a temporary, disposable conversion over a new parallel
renderer; never overwrite the user's source file.
4. **`swift-azw3` is out of scope for reading.** It writes AZW3/KF8 from a
structured manifest for Kindle delivery; it does not read AZW3 or MOBI. Its
manifest has macOS support, but Honeycrisp has no device-delivery goal. Revisit
only if export or Kindle device delivery becomes an explicit product feature.
5. **HTML and TXT are deferred.** They need explicit encoding, resource,
security, and reading-position behavior. Add them only after the main formats
are stable and concrete user needs warrant the added surface.
6. **Do not integrate Readium Swift Toolkit in this macOS app at present.** Its
format coverage is attractive, but the checked-out package is iOS-targeted and
its navigator APIs are UIKit-oriented. Reconsider only if Readium adds a
supported macOS navigator or Honeycrisp changes platform strategy.
7. **Do not adopt `EPUBKit` just to replace the current parser.** It is an
EPUB 2/3 parser, not a renderer or format-expansion solution. Compare it
against Honeycrisp's parser on the corpus and borrow or adopt focused parsing
components only if they materially improve correctness and maintenance.
8. **Markdown packages and `epub-reader-light` do not expand useful book-format
coverage for this product.** They are respectively markup renderers or a
replacement EPUB UI; do not add them as format adapters.

## Architecture rules

- Keep `ReaderViewController` as the EPUB-specific WebKit implementation.
  Avoid broad refactors until there is a second concrete format to support.
- Add a small file-type dispatch layer at the open boundary, keyed by file
  extension and validated content type. It should route EPUB/KEPUB, PDF, and a
  validated MOBI-family import to focused reader/import paths.
- Share only genuinely common behavior: window lifecycle, open/recent routing,
  title display, and generic error presentation. Keep positions, navigation,
  search, and rendering native to each format.
- Do not build a generic `Document`/`Publication` framework or make every
  reader conform to speculative protocols. Introduce a narrow protocol only
  when a second implementation demonstrates a real shared contract.
- If MOBI/AZW conversion uses temporary EPUBs, store them in an app-owned
  temporary directory, use collision-safe names, clean them up reliably, and
  key reading progress to the original source URL plus a stable source
  fingerprint where practical. Keep history and bookmarks attached to the
  original file, not a transient converted path.
- Continue to treat EPUB content as untrusted input. Keep script restrictions,
  URL/resource validation, and safe JavaScript message encoding in place.
- Preserve the macOS 13 deployment target and Swift 5.9 project compatibility
  unless a selected dependency requires a separately reviewed change.
- `project.yml` is the XcodeGen source of truth. Do not hand-edit the generated
  `.xcodeproj`.

## Current implementation to retain or reassess

- Retain the existing EPUB window, pagination/scroll modes, WebKit reading
  surface, parsing, TOC, search, bookmarks, and opt-in reading aids unless
  sample validation identifies a concrete defect.
- The existing parser retains EPUB manifest, spine, version, landmarks, and
  navigation data; it should remain the baseline for comparison with EPUBKit.
- `HistoryManager` stores recent URLs and EPUB progress. Before adding PDF or
  import-conversion progress, separate format-specific position records from
  URL/security-scoped access only as needed. Avoid a wholesale persistence
  rewrite.
- Existing tests use generated synthetic EPUB fixtures. Extend this pattern
  for parser/importer unit tests. Keep the local sample corpus out of test
  resources unless source and redistribution permissions are documented.
- Prior feature work may be retained, simplified, or removed if review shows
  it conflicts with these boundaries or produces behavior without a clear use
  case. Favor removing speculative abstractions over preserving sunk cost.

## Feature request disposition (features.txt 1–29)

| # | Request | Plan decision |
|---:|---|---|
| 1 | Blank-window drag/drop prompt and inset icon | Implement a full-window EPUB file drop target, shaded down-arrow, and no Open Book button; visual review remains. |
| 2 | Other ebook formats | Add PDF; evaluate MOBI/AZW3 import; defer HTML/TXT as described above. |
| 3 | PDF page navigation, page 1 correction, TOC/manual outline | Include PDF in Phase 4 with physical page navigation, configurable displayed page offset, native PDF outline, and app-owned editable outline fallback when no outline exists. |
| 4 | More bookmarks and return to open books | Keep multi-position bookmarks and Open Recent. Treat a page marker as an affordance for the existing bookmark action, not a separate persistence model. |
| 5 | Themes and EPUB metadata | Retain reader themes and metadata-based book identification. Review Nectar theme ideas, but do not port its theme system wholesale; keep publisher CSS ignored unless a separate theme decision changes that boundary. |
| 6 | Fichub/browser-generated EPUB compatibility | Include in Phase 1 corpus validation and fix general parser/resource/navigation issues. |
| 7 | Jump to body content, skip publisher/cover pages | Keep Start Reading as best-effort landmark/front-matter navigation; add an independent “skip cover” preference only where a cover is reliably identified. No promise to skip every publisher page. |
| 8 | Headphone-jack and ordinary clickers | Support only events macOS exposes as keyboard/media input; document tested devices and avoid promising analog jack support. |
| 9 | Extra page/scroll advance buttons | Include discoverable previous/next page and scroll actions in menus/toolbar where the current mode supports them. |
| 10 | Hold button to change scroll speed | Include as an optional input behavior after key/button mapping is stable; clamp speed and stop on release/focus loss. |
| 11 | Auto-scroll | Keep as an opt-in EPUB scroll-mode reading aid. |
| 12 | macOS voices and word highlighting | Keep native macOS speech opt-in. Word-level highlighting is a follow-up gated on reliable speech-to-rendered-text mapping. Do not add cloud/AI voices. |
| 13 | Side-by-side automatic translation | Out of scope: requires translation service, language UI, and a larger layout/data policy. |
| 14 | Compare Nectar, NetNewsWire, Apple Books; highlights/notes | Use them as design references. Keep Honeycrisp intentionally reader-focused. Defer highlights/notes until anchoring, export, and storage are designed. |
| 15 | Liquid Glass | Include visual review on supported macOS, preserving reading contrast and current deployment target. |
| 16 | Search field focus | Completed in Phase 3; preserve a regression check. |
| 17 | Search selection from context menu | Completed in Phase 3; preserve a regression check. |
| 18 | Contextual search-results popup | Include excerpts, chapter/location, and navigable results in the existing centered search UI; do not replace it with a menu popup. |
| 19 | Self-organized library, Quick Look then window | Keep Honeycrisp as a reader with Open/Recent/history, not a library manager. Quick Look is important and explicitly scheduled as later work: inspect the local extension, assess compatibility/maintenance, then implement or replace it as a maintained companion target. |
| 20 | macOS 26 squircle icon and cutout/skeuomorphic direction | Include icon exploration and small-size/Finder/Dock review in Phase 7; keep artwork replaceable and independent of reader code. |
| 21 | Complete menu bar commands | Include native File/Edit/View/Reading/Bookmarks/Window commands for supported open, navigation, appearance, font, columns, fullscreen, and bookmark actions. Do not add unsupported edit commands just to fill a menu. |
| 22 | Shortcut reminders | Show key equivalents on menu items and keep them synchronized with user bindings. |
| 23 | Speech settings and AI voices | Include installed native voice/rate controls. Exclude online/AI voices from this plan. |
| 24 | Paged-mode columns | Keep the existing column setting; verify live changes, menu labels, and small-window behavior. |
| 25 | Break reminders, time limits, statistics, goals | Defer. If later pursued, every reminder must be opt-in and disableable; do not add statistics/goals without a separate product decision. |
| 26 | Skip images and cover page | Implemented as two separate preferences: hide images reversibly, and skip only an EPUB spine item explicitly identified by a cover landmark when no saved position exists. |
| 27 | Build/maintain Honeycrisp's own Quick Look extension | Important later deliverable. Keep it out of the reader critical path, but add a dedicated phase after format dispatch: inspect the local `epub-quicklook-extension`, identify stale APIs/packaging risks, then own the extension target and validate Finder preview plus “Open in Honeycrisp.” |
| 28 | Ignore local samples/private artifacts | Repository hygiene action, not product scope. Keep `samples/` and generated/private artifacts ignored where appropriate; do not broadly ignore roadmap or useful docs. |
| 29 | Open next work in an AO3 series | Include as an opt-in later feature. Nectar already has tested AO3 work/series ID parsing and series metadata with part index and adjacent-work URLs. Reuse the focused parsing/data concepts; do not bring over Nectar's networking, accounts, or broad AO3 stack. Match local siblings using IDs/series metadata, ask when there are multiple candidates, and never fetch from AO3 as part of this local reader feature. |

### Later work explicitly retained

- **Quick Look (request 27):** important and scheduled after format dispatch
  and core reader reliability. The plan is to inspect the local extension,
  then maintain an owned target with explicit macOS deployment, packaging,
  preview fidelity, and open-in-app behavior.
- **Next AO3 series work (request 29):** opt-in later feature using local
  identifiers and sibling matching. Nectar's `AO3Link` extraction and
  `ParsedSeriesEntry`/`ArticleSeriesEntry` concepts already cover work IDs,
  series IDs, part indexes, and previous/next work URLs. Reuse the narrow
  metadata/parsing concepts; keep this feature offline and avoid copying
  Nectar's account, networking, feed, or navigator implementation. Handle
  missing IDs, duplicate files, multiple series membership, and stale
  metadata with an explicit chooser rather than guessing.
- **Repository ignore policy (request 28):** repository hygiene, not reader
  functionality. Keep local samples and generated/private artifacts ignored
  without broadly ignoring plan documents or useful project documentation.

## Phased implementation

### Phase 0 — Baseline and local format matrix

**Status: Blocked on local review.** Sample classes are inventoried in
`docs/compatibility-corpus.md`, but source/license review and actual
compatibility observations remain pending.

1. Record sample format and intended role without recording story text or
   committing sample files:
   - EPUB: AO3, fichub, FicLab, FimFic, Gutenberg, Standard Ebooks, and
     browser-generated samples.
   - KEPUB: `standardebooks.kepub.epub` (EPUB container with Kobo-specific
     content behavior).
   - MOBI: `ao3.mobi`.
   - AZW3: `ao3.azw3` and `standardebooks.azw3`.
   - HTML/TXT: FimFic and AO3 samples.
2. For each file, record only parser/open success, metadata presence, resource
   and TOC behavior, and rendering/navigation defects. Keep source and
   redistribution status separate from observed technical compatibility.
3. Capture current Honeycrisp behavior for EPUB samples before replacing or
   wrapping the parser. Check EPUB2/3 structure, images, links, TOC, scroll,
   pagination, search, and resume.
4. Validate samples only on the local machine. Do not add personal or
   unlicensed book content to Git or generated test fixtures.

**Acceptance:** A local matrix distinguishes validated, failed, and untested
formats; expected behaviors can be reproduced without exposing book content.

### Phase 1 — Keep EPUB quality and KEPUB compatibility

**Status: Reader feature slice implemented; sample validation pending.** Existing
EPUB parsing, TOC, bookmark, and reader behavior has synthetic coverage. The
request 26 image and explicit-cover preferences are implemented. Real EPUB and
KEPUB observations have not been recorded.

1. Run the existing reader against each EPUB/KEPUB sample and fix general
   parsing, URL-resolution, image, and navigation issues before adding
   source-specific exceptions.
2. Compare Honeycrisp's parser with local EPUBKit APIs/tests for meaningful
   gaps. Do not add EPUBKit as a dependency unless it demonstrably replaces
   duplicated or incorrect parsing while preserving the current reader's
   integration needs.
3. Keep KEPUB-specific behavior behind narrow compatibility handling based
   on observed markers/content; do not fork EPUB parsing or position storage.
4. Retain title/author fallbacks, manifest-declared EPUB3 navigation, NCX
   fallback, fragment-preserving TOC, active chapter selection, and
   conservative Start Reading behavior.
5. The General settings pane has reversible “Hide images while reading” and
   “Skip cover when opening” preferences. Cover skipping requires an explicit
   EPUB cover landmark and only affects a fresh position; it never removes an
   uncertain opening chapter or overrides a saved location.

**Acceptance:** Existing EPUB behavior remains intact, KEPUB opens through the
same path, and fixes are backed by synthetic regression tests or documented
local observations.

### Phase 2 — Format-aware open boundary

**Status: Planned.**

1. Centralize supported file types in one open/import registry used by the
   Open panel, drag-and-drop, Finder events, and Open Recent validation.
2. Dispatch EPUB/KEPUB to the existing reader and PDF to a PDF reader. Show a
   clear unsupported-format error for MOBI-family files until the importer
   passes Phase 3 validation.
3. Keep format dispatch explicit and small; do not introduce speculative
   document protocols.

**Acceptance:** Every entry path resolves the same format handler and reports
unsupported or malformed input consistently.

### Phase 3 — MOBI/AZW3 import feasibility and implementation

**Status: Planned; dependency gate required.**

1. First test `libmobi-swift` as a local package against Honeycrisp's macOS
   deployment target and Swift toolchain. Inspect its bundled libmobi license,
   C build settings, architecture support, and parser/error behavior. The
   README claim alone is insufficient because its manifest lists iOS only.
2. Validate `Mobi(url:)`, `getRawml()`, `createEpub(dstEpub:)`, metadata, and
   cover access with `ao3.mobi` and both AZW3 samples. Do not log or check in
   extracted prose.
3. Prefer `createEpub` followed by the existing EPUB reader if output preserves
   readable structure, images, TOC, and links. If it does not, build a narrow
   MOBI importer that maps extracted HTML/resources/metadata into the existing
   reader input without leaking C pointers across the boundary.
4. Do not silently accept DRM-protected or unsupported variants. Show a useful
   error and leave the original file untouched.
5. Add the dependency only after macOS builds, sample outcomes, license, and
   failure behavior are reviewed. If it fails those gates, keep MOBI/AZW3
   unsupported and document an external conversion workflow rather than
   carrying an unmaintainable fork.

**Acceptance:** Both MOBI and AZW3 samples either render through a reproducible
import path with metadata/content/navigation intact, or fail clearly with no
source mutation. No sample-specific prose is committed.

### Phase 4 — Native PDF reader

**Status: Planned.**

1. Use PDFKit's `PDFView` for fixed-page display; do not convert PDF to EPUB or
   HTML.
2. Add PDF file opening, drag/drop, Finder routing, and recent-file handling
   through the format-aware open boundary.
3. Persist zero-based physical page index separately from EPUB spine/character
   offsets. Restore safely if the PDF page count changes.
4. Use PDF document metadata and outline when available. Keep PDF search and
   text selection native to PDFKit; don’t claim feature parity with EPUB
   search/bookmarks until implemented.
5. Add minimal PDF-specific UI/tests for open failure, page restore, outline,
   and malformed/empty documents.

**Acceptance:** Local PDF samples open and restore their page; EPUB behavior
and persistence remain unchanged.

### Phase 5 — Shared reader shell and persistence audit

**Status: Planned after two formats work.**

1. Review duplicated window-level behavior across EPUB and PDF and extract only
   proven shared responsibilities such as title, file identity, and generic
   open state.
2. Keep format-specific TOC, navigation, search, and reading-position models.
3. Audit bookmarks: EPUB bookmarks remain spine + UTF-16 offset; PDF bookmarks
   use physical page index. Store them in a versioned, format-discriminated
   representation with safe decoding and migration tests.
4. Ensure recent-file bookmarks/security-scoped access always refer to source
   files, including MOBI/AZW inputs whose rendered content may be temporary.

**Acceptance:** Opening multiple formats does not cross-wire history, progress,
or bookmarks, and no abstraction duplicates format-specific state.

### Phase 6 — Text formats (deferred)

**Status: Deferred.**

Only revisit HTML/TXT after EPUB, PDF, and the MOBI feasibility gate. Define
encoding detection, local resource policy, script handling, pagination,
metadata, and position semantics first. Markdown renderers such as Tidemark,
Textual, MarkdownView, and Swift MarkdownKit do not solve HTML/TXT import and
are not ebook-format packages.

### Phase 7 — Product polish and visual review

**Status: On-device visual review pending.**

1. Review icon, toolbar, menus, popovers, and Settings on supported macOS
   versions; prioritize legibility and a calm reading canvas.
2. Verify native PDF controls fit Honeycrisp's window conventions and do not
   imply EPUB-style pagination controls.
3. Keep notes/highlights, library management, sync, device delivery, and
   conversion/export as separate product decisions.

### Phase 8 — Quick Look companion extension

**Status: Important later work.**

1. Audit `../swiftreference/epub-quicklook-extension` for current Quick Look
   APIs, supported macOS versions, packaging, and whether its existing preview
   matches Honeycrisp's reading presentation.
2. Build and maintain a Honeycrisp-owned extension target (adopt or replace
   after the audit). Keep it isolated from the main reader process and share
   only stable parsing/rendering code that can be safely reused.
3. Define preview behavior for EPUB/KEPUB first, then decide whether PDF uses
   system Quick Look. Include clear handoff to open the full reader window.
4. Validate install/update behavior and Finder previews on the supported macOS
   range; an extension that only works from Xcode does not meet acceptance.

**Acceptance:** Installed Honeycrisp provides a dependable local-file preview
and a clear route from preview into the full reader.

### Phase 9 — Optional AO3 series navigation

**Status: Planned; local-only and toggleable.**

1. Define a small persisted AO3 identity value from reliable EPUB metadata or
   source URL: work ID, each series ID, part index, and adjacent work IDs when
   present. Avoid title-based guessing.
2. Reuse the focused extraction rules in Nectar's local `AO3Link` and series
   metadata model. Do not copy AO3 networking, account/session, feed, or
   `AO3SeriesNavigator` fetch behavior.
3. When enabled, locate candidate sibling EPUBs in the same directory using
   series/work IDs and part order. Show a chooser for zero/multiple/ambiguous
   matches and never open a candidate silently.
4. Keep the feature off by default until validated. Test absent metadata,
   duplicate conversions of one work, works in multiple series, stale part
   order, and the next/previous boundary.

**Acceptance:** With the setting enabled, a reader can navigate to a uniquely
identified adjacent local work; ambiguity is shown to the user and no network
request is made.

## Deferred package and product options

- **Readium Swift Toolkit:** Broad EPUB/PDF/CBZ/audio functionality, but the
  checked-out package is iOS-only and its navigator depends on UIKit. Not a
  current macOS integration choice.
- **Tomo:** Useful reference for a native macOS EPUB/PDF reader and for
  separating format-specific reader paths. It is a complete AGPL-3.0 app, not
  a reusable reader package; review its license before copying implementation
  code. Learn from its architecture without importing its whole application.
- **`swift-azw3`:** MIT-licensed writer from a structured book manifest,
  supporting AZW3/KF8 output. It is for a future export/device-delivery goal,
  not reading input.
- **`libmobi-swift`:** Candidate reader/import adapter, pending platform,
  license, and sample validation. Its C-backed implementation merits careful
  boundary and failure-path review.
- **EPUBKit:** Candidate parser reference only. Avoid duplicate EPUB parsers
  until corpus comparison demonstrates a concrete advantage.

## Cross-cutting implementation rules

- Do not add tests or build dependencies just to explore a candidate. For
  implementation phases, add focused tests for behavior being changed and run
  the project's existing verification workflow.
- Never modify or delete user sample files. Never copy their prose into source,
  logs, tests, documentation, or screenshots.
- Do not claim format support from extension matching alone; validate content
  and surface unsupported encryption/variants explicitly.
- Keep C-backed libraries behind Swift value-oriented adapters. Do not expose
  raw pointers or native handles to reader/UI code.
- Preserve user files: conversion output is temporary/app-owned unless the user
  explicitly chooses an export destination.

## Engineering workflow recommendations

### Near term — formatting and focused tests

- A checked-in Apple `swift-format` configuration and documented local lint
  command are available. Start with touched files, then enable CI enforcement
  after the baseline is clean. Avoid a repository-wide formatting-only diff
  mixed into feature changes.
- Continue the existing XcodeGen + `xcodebuild test` CI flow. Add focused tests
  around parser boundaries, URL/path resolution, persistence migrations,
  format dispatch, and error cases. Keep personal/local ebooks out of test
  resources; generate small synthetic fixtures instead.
- Keep XCTest for now. Consider Swift Testing only after checking the project's
  Xcode/Swift toolchain and deployment setup; changing test frameworks is not a
  prerequisite for improving coverage.

### Later — signed releases and Sparkle

- Add Sparkle only when Honeycrisp offers a signed, notarized direct-download
  build. The updater needs a stable appcast, an EdDSA signing key, monotonic
  build numbers, release signing/notarization, and a packaged artifact users
  can update in place.
- Keep Homebrew-managed installs on the Homebrew update path. Do not have
  Sparkle update a package-manager-owned installation.
- When direct distribution is ready, create a tag-triggered release workflow:
  archive, sign, notarize/staple, package, sign the Sparkle update, publish
  release notes and appcast. Store signing/notarization secrets in CI and keep
  release credentials out of the repository.
- Add a menu-bar “Check for Updates…” command and test update discovery and
  installation on a signed test build before enabling automatic checks for
  users.
