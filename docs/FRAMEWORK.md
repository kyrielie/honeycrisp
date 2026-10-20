# Honeycrisp framework (target design)

Status: design, not implemented. `ARCHITECTURE.md` describes what the code does today; this file
describes what it should become and the rules that keep it there. `docs/ROADMAP.md` says in what
order. Where this file and the code disagree, the code is current and this file is the goal.

Why this file exists: the app grew feature by feature on one reading surface, so layers, contracts
and ownership were implicit. The result was bugs that come from missing contracts (offset drift,
duplicated URL rewriting, style stripping that loses meaning) and plans that conflicted with each
other. This document makes the structure explicit so each change has a home, a contract and a test.

## 1. Product

Honeycrisp is a native macOS reader for local files, built with AppKit and WebKit. SwiftUI is used
only for the `@main` shim. It reads flowing text formats (EPUB, Markdown, plain text, and MOBI/AZW3
through conversion) and fixed-page formats (PDF, CBZ). One window per open book. No library view.

Principles, in priority order. When two conflict, the earlier one wins.

1. Reading comes first: position is never lost, text is legible, themes never reduce contrast below
   the floor.
2. Data is never destroyed: stored data survives bad entries, downgrades and layout changes.
3. Book content is untrusted input, always.
4. Respect the book, own the reading experience: keep the book's meaning-bearing styling, override
   only the properties the user controls.
5. Small and native: AppKit and WebKit, few dependencies, no background services.

Non-goals: library view, cross-book search, quote sharing, translation, cloud or AI voices, sync,
export, statistics, per-window or per-book reading mode. A proposal that needs one of these is a
product change and must go through the admission checklist in section 6, not slip into a milestone.

## 2. Layers

```
 L5  Shell        windows, menus, toolbar, sidebar, settings, popovers          AppKit
 L4  State        Locator, history, bookmarks, navigation history, settings    pure Swift + UserDefaults
 L3  Surface      FlowingSurface (WKWebView host) | PagedSurface (PDFKit/images) WebKit, PDFKit
 L2  Content      sanitize, transform, style layers, text extraction            pure Swift (+ SwiftSoup)
 L1  Publication  format-neutral model: metadata, resources, reading order, TOC pure Swift
 L0  Format       EPUB, Markdown, TXT, PDF, CBZ, MOBI->EPUB adapters            Foundation, ZIPFoundation, PDFKit
```

Dependency rule: a layer imports only from layers below it. L0 to L2 import no AppKit and no WebKit
(PDFKit is allowed only in the PDF adapter and `PagedSurface`). L3 never reads `UserDefaults`; it
receives settings as values. L4 never touches the DOM; it speaks only in `Locator`. L5 never parses
a book.

Cross-cutting: Settings (L4, one source of truth), Persistence (L4, versioned and durable), Trust
(enforced at L2 and L3), Tests (section 5).

### Where the current code sits

| Today | Layer(s) | Target home |
|---|---|---|
| `Parsing/EPUBParser.swift` (models, unzip, OPF, search, HTML, CSS, JS in one file) | L0, L1, L2, L3 mixed | split by layer: `Format/EPUB`, `Publication`, `Content`, `Render` |
| `Parsing/TOCParser.swift` | L0 | `Format/EPUB` |
| `Reader/PaginationEngine.swift`, `PaginationJS.swift` | L3 | `Render/Flowing` |
| `Reader/ReaderViewController.swift` (state, navigation, speech, search host, toolbar, settings reaction) | L3, L4, L5 mixed | shell controller plus session objects; extract by contract, not by size |
| `History/*` | L4 | `State` |
| `Settings/SettingsManager.swift` | L4 | `State/Settings` |
| `Settings/*Controller`, `Sidebar/*`, `App/*` | L5 | `Shell` |

The split is mechanical and behavior-neutral, done one layer boundary at a time (roadmap M1, M3,
M5). Do not reorganize directories ahead of the contract that justifies it.

## 3. Contracts

Each contract has one owner, one definition and at least one test. Changing a contract means:
update this section, bump any persisted version, add or change a test, say so in the PR.

### C1. Locator (the only currency between L3, L4 and L5)

```
Locator = flow(resource: Int, offset: Int, layout: Int, fraction: Double)
        | page(index: Int)
```

- `resource` is the zero-based reading-order index. `offset` is the UTF-16 length of text-node
  characters before the position, in DOM order, within that one resource's rendered content.
  `layout` is the version of that definition. `fraction` is the position inside the resource from
  0 to 1, stored as the fallback.
- Restore rule: if the saved `layout` equals the current one, seek by `offset`. Otherwise seek by
  `fraction`. Today `anchorLayout` is stored but nothing reads it; this closes that gap.
- Book progress is derived, never stored as truth: weighted by known text length per resource,
  falling back to resource byte size until lengths are known. Do not derive it from total scroll
  height (estimated heights made global percentages unstable in the Sumra reference).
- Bump `layout` whenever sanitizing, transforming or extraction changes which characters count.

### C2. Offset parity

One definition of an offset exists: the text-node walk performed by the page script on the live DOM.
Swift-side extraction (search, speech, length estimates) must produce identical offsets for the
same served chapter. Enforced by a parity test that loads synthetic chapters in a real `WKWebView`
and compares JS offsets with Swift offsets, including entities, supplementary Unicode, whitespace
and self-closing tags. Any change to L2 output requires this test to pass.

### C3. Publication and chapter shape

- `Publication` (L1): metadata (title, authors, language, identifiers), reading-order resources,
  TOC tree, cover reference, and a `kind`: flowing or paged.
- Flowing resource: an id, a href, a media type, and a way to obtain bytes. The Content layer turns
  it into a served chapter. Markdown and plain text are converted to chapters at L0; MOBI and AZW3
  are converted to a temporary EPUB at L0. Nothing above L1 knows the original format.
- Paged publication: a page count, per-page rendering owned by the paged surface, an optional
  outline. PDF and CBZ are paged. A paged publication is not forced into the chapter shape.
- The abstraction is narrow: it carries only what L2 to L5 read. Add a field when a second consumer
  needs it, not before.

### C4. Style cascade (flowing content)

Order inside each chapter document: (1) app reset, minimal and defensive (box sizing, image and
table containment); (2) the book's own styles, left intact; (3) the user layer.

The user layer owns exactly these properties: font family, base size, text and background color,
line height, link colors, body width and margins, image size, and the optional text alignment,
hyphenation, paragraph spacing and bold weight. It sets them through CSS variables.

It never touches: italics, bold, small caps, underline, `white-space`, centered or right-aligned
text, `display`, text direction, list styles.

Mechanism for the optional properties: element-type selectors without `!important`
(for example `p { text-align: var(--reader-text-align) }`). A book's class or inline rule is more
specific and wins, so centered verse and titles survive. Verify in a rendered fixture before
relying on it. Owned properties that must win (font family, color) use `!important` and `revert`
on descendants.

Each chapter is its own document so book class names cannot collide across chapters (see C5).

### C5. Chapter host

The flowing surface shows a window of chapters: the current chapter plus neighbors, mounted near
the edges, evicted when far. One `WKWebView` per book remains; chapters are separate documents
inside it. Properties the host must provide:

- Isolation: styles and ids of one chapter cannot affect another.
- Relative resource URLs resolve by the browser, not by string rewriting.
- XHTML chapters load as XML so self-closing tags behave.
- A stable position model across chapter boundaries: prepending a chapter above the viewport must
  not move the visible text.
- Bounded memory on very long books (target set by the spike in roadmap M3, measured on a synthetic
  2,000-page fixture).

How the host is built (iframe per chapter is the current candidate) is decided by the M3 spike. The
contract above is what the rest of the code depends on, so the construction can change.

### C6. Trust boundary

- Book bytes are untrusted at every layer, including after sanitizing (defense in depth).
- L2 removes active content from chapters: `<script>`, event-handler attributes, `javascript:`
  URLs. It uses a real parser, not regular expressions.
- L3 serves book resources only through the app's scheme handler. The handler resolves paths
  against the book root and rejects anything that escapes it, and it fixes the MIME type. It does
  not serve the network.
- Author JavaScript is off. The app's own scripts run in a separate content world or as user
  scripts. Verify the exact WebKit behavior on macOS 13 before building on it (roadmap section 7).
- Strings from a book are never interpolated into JavaScript; use
  `EPUBParser.javaScriptStringLiteral` (to be renamed when L2 splits).
- Values interpolated into CSS pass `ReaderCSSSanitizer`.
- Archive extraction relies on ZIPFoundation's containment checks (verified for 0.9.20). Entry-count
  and size limits are intentionally not enforced.

### C7. Persistence

- `UserDefaults` only. No database. Keys are owned by exactly one type.
- Every stored record is versioned and decoded per element. A record that fails to decode is
  preserved and written back; a newer version than the app knows is never overwritten
  (`StorageQuarantine`).
- Records carry a format discriminator once a second format exists, so a PDF page locator is never
  decoded as a flow locator.
- File identity is the path, with a security-scoped bookmark. Moving a book orphans its position.
  This is a known and accepted limit.
- Retention is separate from display: history may retain more entries than the recents menu shows.

### C8. Settings

- `SettingsManager` is the only writer of `reader*` keys. Setters notify.
- A change is either cosmetic or structural. Cosmetic: patch CSS variables in all mounted chapters,
  no reload. Structural: re-render the mounted window and restore the `Locator`.
- Appearance (system, light, dark) is a setting, not a theme. A theme holds light and dark color
  sets plus typography. Reset functions and the "customized" check must include every new field.
- New persisted theme fields use `decodeIfPresent` with defaults.

### C9. Commands and capabilities

- Every user action is a command with a menu item, an optional rebindable shortcut and an enabled
  state. Toolbar buttons and menu items are views of the command, never separate code paths.
- A reading session declares capabilities: themeable, searchable, speakable, paginatable, has
  outline, supports bookmarks and back/forward. The shell enables or hides commands from the
  capabilities. PDF and CBZ simply lack some of them. No `if format == pdf` in the shell.

### C10. Chrome tokens

Window chrome (title, toolbar, materials, sidebar, popovers) reads from one small set of chrome
definitions in L5, so a platform generation (for example Liquid Glass on macOS 26) is added in one
place behind an availability check, and the reading surface is never restyled by it.

## 4. Data flow (target)

```
file -> L0 adapter -> Publication -> L2 pipeline (sanitize, transform) -> served chapter
     -> L3 host (+ style cascade, user layer) -> page script reports Locator
     -> L4 stores Locator, history, bookmarks -> L5 shows title, progress, menus
settings change -> L4 notifies -> L3 patches variables (cosmetic) or re-renders (structural)
search/speech  -> L2 text extraction (parity with C2) -> Locator -> L3 scrolls and highlights
```

## 5. Testing

| Level | What | Rule |
|---|---|---|
| Unit (pure) | Locator math, progress, sanitizer, navigation history, theme codec, history and bookmark durability | every pure type ships with tests |
| Pipeline | synthetic chapter fixtures in, expected served HTML and extracted text out | fixtures are generated in temp directories; never add real EPUBs |
| WebKit harness | parity (C2), style cascade (C4), host behavior (C5) in a real `WKWebView` | required before any L2, L3 or C4 change merges; started: `WebKitOffsetParityTests` exists, and its parity and rewrite cases are expected failures until the merged document is replaced (roadmap M3, decision B1) |
| Device | local `samples/` runs recorded in `docs/compatibility-corpus.md` | observed outcome only, never copy book content |

A change to an untested area (`SettingsManager`, `KeyBinding`, `PaginationEngine`,
`ReaderViewController`, search UI) says so in the PR. The build environment may lack a macOS
toolchain; do not claim a build or test passed unless it was run.

## 6. Rules that keep it coherent

1. One home per concept. Locator is defined once (L4). Offsets are defined once (C2). Style
   ownership is defined once (C4). A second definition is a bug.
2. Admission checklist for any feature: which principle does it serve, which layer owns it, which
   contract does it touch, what is the test, what is the setting and its default, which non-goal
   does it brush against. A feature with no answer to "which layer" is not ready.
3. No abstraction without two consumers, except the contracts above, which exist because the plan
   already has two consumers (flowing and paged, search and speech).
4. Spikes are time-boxed, flagged, and have written exit criteria. The outcome is recorded as a
   decision in the roadmap, then the spike code is either promoted or deleted.
5. Documents: one design (this file), one plan (`docs/ROADMAP.md`), one code map (`INDEX.md`), one
   as-built description (`ARCHITECTURE.md`), the corpus (`docs/compatibility-corpus.md`), and
   rules for contributors (`CLAUDE.md`). Superseded documents are deleted, not archived; git keeps
   history. A milestone is not done until the affected document is updated.
6. Evidence over assertion. Mark anything unchecked as unverified. APIs, versions and package names
   are verified from docs or source before being relied on.
7. Persisted data changes ship with a migration or a defaulting decode, and a test.
