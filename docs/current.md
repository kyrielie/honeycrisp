  ## AO3 EPUB parsing from Ambrosia: what's relevant
  Ambrosia's AO3MetadataExtractor (Database/AO3MetadataExtractor.swift) parses the AO3
  preface chapter into structured metadata (fandoms, rating, warnings, series, word count,
  etc.) using SwiftSoup on dl.tags. None of this needs to be ported. Honeycrisp is a
  reader, not a library manager — it has no metadata search, no DB, no slot for that
  record. The two AO3-specific rendering issues are already handled:

  • .toc-heading hiding: covered twice (CSS harvest via R21, and ChapterTransforms.
  applyAO3Formatting)
  • b.calibre2 chapter-title styling: covered by ChapterTransforms.applyAO3Formatting
  ──────
  ## Recommended next work

  ### 1 (S) — Speech highlight + search hit fix (do this first)

  Root cause (Verified in ReaderStyles.swift:131-237):

  The universal rule * { background-color: transparent !important } (line 233) overrides
  the background: shorthand on mark.ql-hit, .hc-sp-s, and .hc-sp-w — the shorthand expands
  into background-color, so !important wins. The fixes:
  • Change all three rules to use background-color: <var> !important instead of background:
  <var>
  • Add #hc-speech-hl { max-width: none !important } to prevent the paginated * { max-
  width: 100% !important } from collapsing the overlay container
  • Extend FlowSpeechHighlightTests to load the full readerCSS and assert computed colors
  are not transparent (currently the test never loads readerCSS, so it can't see this
  defect)
  No currentLayout bump; overlay is JS-positioned, not part of the text-node walk.
  ### 4 (S) — Dead code removal

  Remove FlowSurfaceFlag and its test, the six forwarders at the end of
  EPUBParser.swift:292-337 (moving call sites to ReaderStyles/ReaderScripts directly), and
  the stale XCTExpectFailure in WebKitOffsetParityTests. Update INDEX.md in the same pass.

  ### 5 (M) — Test gaps
  KeyBinding, SettingsManager setters beyond themes/speech, PaginationEngine navigation —
  all confirmed untested per INDEX.md.

  ### 6 (M) — M8 Chrome

  Title/subtitle toolbar, combined Aa popover. No blocking decisions; independent of
  pipeline.
  ──────

  Starting with item 1. I'll fix the CSS, extend the tests, then move to item 4 (dead
  code).

  Let me first check the existing speech highlight tests and the contrast tests to
  understand exactly what to add:

  I see the problem: ReaderContrastTests.testReaderCSSHitRulesUseVariablesAndNoFixedYellow
  (lines 105-114) asserts exact strings like "background: var(--reader-hit-bg);" — these
  will need to be updated when the fix changes background: to background-color: ...
  !important. Let me also check what the FlowSpeechHighlightTests harness does,
  specifically how readerCSS is handled in the loaded page:


  Good. The FlowSpeechHighlightTests harness does NOT include readerCSS in its test page
  (it only adds the vars block inline). The actual readerCSS is baked into the flow
  document via FlowDocumentBuilder. The test can detect the cascaded computed background-
  color by loading the full readerCSS in its synthetic page — which is what the test needs
  to do to catch this bug.

  Now let me implement the fix:



  Now update ReaderContrastTests — the test at line 105 asserts the old background:
  shorthand strings, which must change to match the new background-color: ... !important
  forms:



  Now add the new WebKit tests to FlowSpeechHighlightTests — a test that loads readerCSS
  and asserts computed background-colors are not transparent, and a search-hit color test.
  The existing harness builds its page without readerCSS, so I need a second helper that
  includes it:



  Now update the makeConfiguredFlowWebView helper to accept an includeReaderCSS parameter:



  Now let me verify the complete updated test file looks correct:



The honeycrisp book info panel is not being populated with ao3 metadata, that is why we
  need to reference ambrosia. I would also prefer the styled preface as an option.

  Understood — the goal is to extract AO3 metadata from the preface chapter and populate
  BookInfoViewController with it, and optionally render the AO3 preface as a styled card.
  Let me first read the relevant code before proposing anything:


? For AO3 metadata in Book Info: where should it be extracted? Spine[0] is the preface for
AO3 EPUBs, but plain EPUBs and non-AO3 books have no `dl.tags` there — extraction gracefully
returns nil if the anchor isn't found.

> (Recommended) Try spine[0] first, fall back through spine[1..4] — same heuristic Ambrosia
uses
? The AO3 metadata record has many fields (fandoms, relationships, characters, additional
tags, rating, warnings, series, word count, chapter count, kudos, dates, URL). Which should
appear in Book Info?
> (Recommended) All fields that are non-empty: fandoms, tags, relationships, characters,
rating, warnings, categories, series, word count, chapter counts, completion, dates, story
URL
? For the styled AO3 preface: what should the option do?
> (Recommended) Add a transform that converts the raw `dl.tags` block into a styled HTML card
injected in-place — rendered in the reader as the preface chapter, toggled by a new
Formatting tab setting
? The preface styled card transform: if we go that route, should it reuse the existing
`formatAO3` setting (which already governs other AO3 transforms) or be a separate toggle?
> (Recommended) Separate toggle — 'Show AO3 preface card' in Formatting tab, off by default

  Good. Now let me check test status and read the ambrosia extractor one more time for the
  exact HTML selectors it uses:


  Log is empty — output is buffered. I'll continue planning while it runs. Now I have
  everything I need. Let me write the implementation plan for both features:

  Design decisions resolved:

  • AO3 metadata extraction: new AO3MetadataExtractor type in Sources/Parsing/, tries
  spine[0..4], returns optional AO3MetadataRecord
  • EPUBPackage gets a ao3Metadata: AO3MetadataRecord? field (transient, not persisted — no
  format change)
  • BookInfoViewController adds AO3 sections when the field is populated
  • Styled preface: new ChapterTransforms.applyAO3PrefaceCard transform, guarded by a new
  SettingsManager.showAO3PrefaceCard setting (off by default), new Formatting tab checkbox

  Key constraint from FRAMEWORK C2: the preface card transform must hide elements, never
  delete them (offset walk counts hidden text). The card is an inserted element; the
  original dl.tags can be hidden in-place. Also, this is a structural transform (re-renders
  on change), so it fires .readerStructuralSettingsChanged.

  Let me now write the plan and begin implementing Pass 1 (extraction + Book Info):

