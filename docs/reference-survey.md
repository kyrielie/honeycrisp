# Reference survey: other Swift projects

Survey of 15 repositories (5,186 files, from a repomix export) for techniques useful to Honeycrisp
(MIT, macOS 13, Swift 5.9, AppKit and WebKit) and to Nectar (iOS companion). Baseline: Honeycrisp
commit `5c3dd27`. Paths below are `repo/path:line` inside the export; Honeycrisp paths are repo-relative.

Status: inspection only. Nothing was built or run. Every Honeycrisp claim cites its own line.

## License handling

| Source license | Repos | Honeycrisp (MIT) | Nectar |
|---|---|---|---|
| MIT | Varq, Octavo, Winston, EPUBKit, FlyingFox, epub-reader-light, swift-azw3, textual, MarkdownView, Tidemark | Port with copyright notice | Port |
| BSD-3 | swift-toolkit (Readium), folioreaderkit | Port with notice, or reimplement | Port |
| Apache-2.0 | swift-markdownkit | Port with notice | Port |
| AGPL | readest, tomo | Study only; reimplement independently | Port allowed (owner decision) |
| CC0 wrapper over LGPL C | libmobi-swift | See F7 | See F7 |

## Triage

| Repo | Verdict | Why |
|---|---|---|
| Varq | Deep dive | Closest sibling (macOS EPUB, PDF, CBZ reader). macOS 15, Swift 6 |
| swift-toolkit | Deep dive | Locator, DRM sniffing, TTS, scheme handler. iOS 15 declared only |
| libmobi-swift | Deep dive | MOBI/AZW3 to EPUB. License chain needs care |
| Octavo | Targeted | Complete notarizing release workflow. macOS 26 only app |
| Winston | Targeted | Only Quick Look extension in the set |
| EPUBKit | Rejected as dependency | See Rejected |
| readest, folioreaderkit | Concepts | Feature ideas only |
| FlyingFox | Rejected | See F9 |
| epub-reader-light | Skipped | Tiny WebKit wrapper; only a queue-until-loaded JS call pattern |
| swift-azw3 | Skipped | Writes AZW3; Honeycrisp does not export or convert |
| Markdown group (4) | Deferred | Only relevant to roadmap Phase 6 (text formats) |
| tomo | Not inspected | Library manager; non-goal for Honeycrisp |

## Findings, ranked

| ID | Finding | Target | Disposition | Effort |
|---|---|---|---|---|
| F1 | Untrusted EPUB web content is not isolated | Honeycrisp | Port from Varq with notice | M |
| F2 | Any `encryption.xml` is reported as DRM | Honeycrisp | Reimplement (Readium rules) | S |
| F3 | Archive extraction has no visible path or size checks | Honeycrisp | Verify, then add | S |
| F4 | Release is ad-hoc signed; Octavo shows a full notarized flow | Honeycrisp | Adapt | M |
| F5 | Reading position has no schema version, href, or text anchor | Honeycrisp | Reimplement minimal | M |
| F6 | Renderer interface and locator shape for multi-format | Honeycrisp | Reference for Phases 2 and 4 | L |
| F7 | MOBI/AZW3 to EPUB conversion | Nectar first | Dependency gate | M |
| F8 | Speech: voice filtering, state machine, continuous playback | Both | Reimplement / port | M |
| F9 | Resource serving: scheme handler, not an HTTP server | Honeycrisp | Optional; reject FlyingFox | M |
| F10 | Quick Look extension shape | Honeycrisp | Reference for Phase 8 | M |
| F11 | Reading-aid and sync ideas | Nectar mostly | Concepts | n/a |
| F12 | Test ideas | Honeycrisp | Take ideas | S |

### F1. Isolate untrusted EPUB content (N14, N5)
Honeycrisp today: JavaScript is on in the page world and the store is non-persistent
(`Sources/Reader/ReaderViewController.swift:166-167`). `extractBody` keeps author markup as is
(`Sources/Parsing/EPUBParser.swift:623`). `rewriteResourceURLs` returns `http`, `data` and
`javascript:` values unchanged (`EPUBParser.swift:631-654`). The navigation delegate cancels only
activated http(s) links and allows everything else (`ReaderViewController.swift:1684-1693`).
`ENABLE_OUTGOING_NETWORK_CONNECTIONS: YES` is set (`project.yml:42`). I found no script or remote
resource restriction in these paths, although `docs/implementation-roadmap.md` says to keep them.
Not exercised at runtime: confirm with a fixture before treating as a confirmed defect.

Varq's approach (`Varq/Services/EpubWebIsolationService.swift`, 54 lines; `Varq/docs/adr/0012-isolate-epub-web-content.md`):
- Refuse to run on a persistent data store.
- Compile a content rule list that blocks every URL except `^file:`.
- Set `allowsContentJavaScript = false` for book navigation (`EpubWebRenderer.swift:684`).
- Run the reader's own scripts in `WKContentWorld.defaultClient` (`EpubWebRenderer.swift:934`).
- Confine navigation to spine files inside the extracted root.
- Verify with real WebKit tests that include an unhardened positive control.

Cost for Honeycrisp: `readerJS` and the pagination JS are inline `<script>` tags in the page
(`EPUBParser.swift:368-370`, `443-444`), so they would stop running once author JS is off. They must
move to user scripts or client-world evaluation, and the five message handlers need registering for
that world. Verify the exact WebKit API availability on macOS 13 from Apple's docs before coding.

### F2. DRM detection is too broad (N6)
`parsePackage` throws `.drmProtected` if `META-INF/encryption.xml` exists (`EPUBParser.swift:137-140`);
the test uses an empty `<encryption/>` file (`Tests/HoneycrispTests/EPUBParserTests.swift:146-160`).
Readium treats that file as also listing font obfuscation: it handles the IDPF and Adobe
algorithms (`swift-toolkit/Sources/Streamer/Parser/EPUB/Resource Transformers/EPUBDeobfuscator.swift:15`)
and classifies DRM only by specific markers (`swift-toolkit/Sources/Shared/Toolkit/Format/Sniffers/EPUBFormatSniffer.swift:57-97`):
- LCP: `META-INF/license.lcpl` exists, or a `RetrievalMethod` URI of `license.lcpl#/encryption/content_key`.
- ADEPT: an `adept:resource` element under `KeyInfo`.
Effect: a book that only obfuscates fonts would be rejected as protected. Honeycrisp strips publisher
CSS, so it never needs the fonts; it only needs to stop rejecting. Before coding, read the namespace
URIs from Readium's `XMLNamespace` definitions rather than recalling them. Tests: font-only,
ADEPT, LCP, and the existing empty-file case (decide its expected result explicitly).

### F3. Archive extraction (N14)
`unpackEPUB` calls `fm.unzipItem` once (`EPUBParser.swift:125`) with no entry-path or size check
in Honeycrisp code. Varq validates each resolved destination stays under the root
(`Varq/Services/EpubPublicationService.swift:77-90`), and its ADR calls archive validation a
separate boundary from the content rule list. Readium checks served files are inside their
directory (`WebViewServer.swift:140-170`). Whether ZIPFoundation 0.9.20 already rejects traversal is
not answerable from this export (its source is absent); check it, and add size and entry-count
limits if it does not.

### F4. Signed releases (N10)
Honeycrisp ships ad-hoc signed DMGs (`.github/workflows/release.yml:50-62`) and a fixed
`CURRENT_PROJECT_VERSION: 1` (`project.yml:38`). `Octavo/.github/workflows/release.yml` (152 lines) shows:
- tag-push trigger and pre-release detection from a `-` in the tag;
- version from the tag and build number from `github.run_number`;
- a throwaway keychain holding the Developer ID certificate;
- notarytool with an API key, requiring `status == Accepted` from JSON and printing the log otherwise;
- `stapler staple`, then `ditto` packaging and a round-trip check (`codesign --verify`,
  `stapler validate`, `spctl --assess`);
- SHA256SUMS in the release assets.
Prerequisites are a Developer ID certificate and an App Store Connect API key. A monotonic build
number is also a precondition for Sparkle, which the roadmap defers.

### F5. Position model (N2)
`HistoryEntry` stores `lastSpineIndex` and `lastCharacterOffset` (`Sources/History/HistoryManager.swift:6-50`).
Varq's `BookLocator` adds `schemaVersion`, `format`, `resourceHref` and `progression`
(`Varq/ReaderEngine/BookLocator.swift`), and its highlight anchor adds a quote selector with prefix
and suffix (`Varq/docs/adr/0004-store-text-highlights-as-versioned-range-anchors.md`). Readium's
`Locator.Text` carries `before`, `highlight`, `after` (`swift-toolkit/Sources/Shared/Publication/Locator.swift:198-201`).
Both exist so a position can be re-verified when content changes. Hypothesis, untested: re-downloaded
fanfiction with edited chapters would benefit from an href plus short quote stored beside the offset.
`HistoryEntry` already tolerates missing fields on decode, and a test covers it (`HistoryEntryTests`).

### F6. Multi-format shape (N3)
Varq's `BookRenderer` protocol (`ReaderEngine/BookRenderer.swift`, 42 lines) has `open(bookURL:at:)`,
`go(to:)`, `goForward/Backward`, appearance and viewport updates, with EPUB, PDF and CBZ
implementations, and detects format by extension plus file signature (`docs/ARCHITECTURE.md`, import
pipeline step 2). This is a worked example for roadmap Phases 2 and 4, which say to add a protocol
only when a second format exists. Not yet read: `PDFBookRenderer.swift`, `CBZBookRenderer.swift`.

### F7. MOBI and AZW3 (N4)
`libmobi-swift` exposes `Mobi(url:)`, `createEpub(dstEpub:)`, metadata getters and `getCover()`
(`Sources/libmobi/Mobi.swift`). `createEpub` matches the roadmap's temporary-EPUB plan. Cautions:
- `LICENSE.md` is CC0, but the vendored C headers say "Licensed under LGPL, either version 3, or any
  later" (`Sources/libmobic/include/mobi.h`). Treat the effective license as LGPL for the C part.
- Package declares `.iOS(.v14)` only; macOS build not verified.
- Vendors about 730 KB of C, and its only test is an empty stub.
- No DRM error mapping is visible in the Swift layer.
For Nectar this is a direct fit. For Honeycrisp (MIT), static LGPL linking is a licensing decision
for the owner; the roadmap already gates Phase 3 on a dependency review.

### F8. Speech (N7)
Readium's engine filters out novelty, Eloquence and Personal voices (`Navigator/TTS/AVTTSEngine.swift:53-67`),
models start, stop and finish races as an explicit state machine (same file, around l.160-280), and
feeds utterances from a content iterator so playback can continue across resources
(`Shared/Publication/Services/Content/`). `docs/implementation-roadmap.md` and `ARCHITECTURE.md` say
Honeycrisp speech does not promise multi-spine playback. Not compared: Honeycrisp's voice list code.

### F9. Resource serving (N5)
Readium serves resources through a custom-scheme `WKURLSchemeHandler` with longest-prefix routes,
directory containment checks, and per-resource transformation (`Navigator/EPUB/WebViewServer.swift:14-170`).
No HTTP server is involved. FlyingFox is a real HTTP server, so adopting it would add server
behavior and likely a new network entitlement that Honeycrisp does not have. A scheme handler would
also remove the regex in `rewriteResourceURLs`, which only rewrites double-quoted `src="..."` and
`href="..."` attributes (`EPUBParser.swift:632`). Varq keeps `loadFileURL` plus read access, so this
is optional unless F1 or the rewrite gaps become a problem.

### F10. Quick Look (N8)
`Winston/WinstonQuickLook/PreviewProvider.swift` (31 lines) is a `QLPreviewProvider` that returns a
cover image through `QLPreviewReply(dataOfContentType:contentSize:)` after extracting off the main
thread. A cover-only preview is a cheap first slice. It needs a new extension target in `project.yml`;
text previews were not found in any repo.

### F11. Feature and sync ideas (not verified in code)
- Readest README: reading ruler, paragraph-by-paragraph mode, RSVP, dictionary lookup, parallel read,
  KOReader progress sync (`readest/apps/readest-app/src/services/sync/KOSyncClient.ts` keys by a
  document digest and stores a percentage).
- folioreaderkit README: media overlays, RTL, reading time left, multiple instances.
These mostly suit Nectar; Honeycrisp non-goals exclude sync and library features.

### F12. Test ideas
`EPUBKit/Tests/EPUBKitTests/EPUBEdgeCaseTests.swift`: empty manifest, empty spine, circular spine
references, empty IDs, odd path formats, a directory passed where a file is expected, deeply
nested TOC. EPUBKit uses Swift Testing; Honeycrisp stays on XCTest per the roadmap. Varq's positive
control (prove the test can observe the bad behavior before hardening) fits F1.

## Rejected

- EPUBKit as a dependency: needs AEXML and Zip (Honeycrisp uses ZIPFoundation); no landmark, nav
  property or encryption handling found by search; Honeycrisp's parser already retains landmarks
  and non-linear spine items.
- FlyingFox: see F9.
- swift-azw3: AZW3 writer only; conversion and export are out of Honeycrisp's scope.
- Markdown group: platform floors differ (textual macOS 15, Tidemark macOS 14, MarkdownView macOS 13,
  swift-markdownkit macOS 11); only relevant if Phase 6 starts.

## Not covered by any repo, or not inspected

- No repo has AO3 or fanfiction-specific logic (roadmap Phase 9).
- Not inspected: tomo source, Octavo beyond its release workflow, Winston beyond Quick Look and
  scripts, Varq's PDF and CBZ renderers, readest beyond README and KOSync, FlyingFox source,
  Readium search and navigator JavaScript, the Markdown libraries.

## Suggested order

1. F2 (small, user-visible, testable).
2. F3 verification, then F1 with a real-WebKit test first.
3. F5 if re-download drift is a real problem for you.
4. F4 when a Developer ID is available.
5. F6, F7, F10 as roadmap phases start.
