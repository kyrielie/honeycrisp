# Honeycrisp Settings Window — Plan for a Pre-Ventura AppKit Rebuild

Scope: `Sources/Settings/SettingsWindowController.swift` (1482 lines: window
controller, tab controller, four pane view controllers) and its wiring in
`Sources/App/AppDelegate.swift`. Reference sources: `macos-settings-window-guide.md`
(the distilled guide) and the `MacAppSettingsUI` reference implementation packed in
`macosappsettings.xml`. Architecture chosen: **A — tab bar, one pane per tab**
(`NSTabViewController`), matching the guide's §1 "classic System Settings pre-Ventura
look." This is also what Honeycrisp already uses, so this plan is a refit of the
existing structure against the guide's checklist, not a rewrite from scratch.

Current state: four tabs (General, Appearance, History, Shortcuts), all built as
plain `NSViewController` subclasses with hand-rolled `loadView()`. The window is
`[.titled, .closable, .resizable]` unconditionally, fixed at whatever frame
`SettingsWindowController.init` set (520×420), with `minSize`/`maxSize` clamps and no
per-tab sizing logic at all — Appearance's much taller content is handled by giving
that one tab an internal `NSScrollView`, not by resizing the window.

---

## 1. Window chrome (guide §2)

### 1.1 Style mask: closable-only by default, resizable opt-in per pane

Today: `styleMask: [.titled, .closable, .resizable]`, set once, never touched again.
No pane in the current four actually needs live resizing — History and Appearance use
internal scroll views specifically to avoid needing it — but General/Shortcuts/History
are short and Appearance is tall, so a fixed one-size-fits-all window is either too
tall for General or too short for Appearance (right now it's fixed and Appearance's
scroll view is papering over that).

Plan:
- Strip `.resizable` from the base style mask; add `resetWindowBehavior()` /
  `addResizableBehavior()` per guide §2.1.
- Give each pane an `isResizableView: Bool` (default `false`), matching
  `SettingsPaneViewController.isResizableView` in the reference. None of the four
  current panes need `true` — the point of §2.3 is that *panes get their own
  correctly-sized window*, not that any pane needs user-resizing. Keep the
  scroll-view fallback in Appearance regardless, as a safety net for whatever the
  window ends up sized to.

### 1.2 Escape / ⌘. closes the window

Verify only — inherited free from `NSWindow` per guide §2.2, and nothing in
`RecorderButton` (Shortcuts tab) or the color wells / text fields (Appearance tab)
should be capturing Escape. Explicitly re-check `RecorderButton`, since a key-capture
control is exactly the kind of thing that can accidentally swallow Escape.

### 1.3 Animated per-tab resize, anchored top-left (guide §2.3)

This is the main structural gap. Today there's no resize-on-tab-switch at all: the
window is one fixed size for all four tabs. Plan:
- Port `resolvePreferredPaneSize()` onto each of the four view controllers: call
  `view.layoutSubtreeIfNeeded()` once content is built, cache the resulting
  `NSSize`.
- Port `setWindowSize(_:animateIfPossible:completion:)` verbatim from the guide,
  including the top-left anchor math (adjust origin by the height delta so growth
  happens from the top, not the bottom).
- Gate on `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` — snap
  instantly when Reduce Motion is on, don't just shorten the animation (guide §6).
- Scale duration to size delta via `animationResizeTime(_:)`, not a fixed number.
- Wire this into `SettingsTabViewController`'s tab-selection callback
  (`tabView(_:didSelect:)`), replacing whatever implicit sizing currently happens.

### 1.4 Window title syncs to the active pane (guide §2.4)

Not currently done — the window title is hardcoded to `"Settings"` in
`SettingsWindowController.init` and never updated. Add `setWindowTitle(with:)`
updating all three of: title bar text (pane name, e.g. "Appearance"), the Window menu
entry via `NSApp.changeWindowsItem(_:title:filename:)`, and `miniwindowTitle`. Low
risk, pure addition.

### 1.5 Disable inapplicable menu items (guide §2.5)

Add `validateMenuItem` override on the window/window controller disabling tab-related
document-window commands (`toggleSidebar`, `toggleFullScreen`,
`selectPreviousTab`/`moveTabToNewWindow`/`mergeAllWindows`, `toggleTabBar`,
`toggleTabOverview`, `toggleToolbarShown`, `runToolbarCustomizationPalette`) per the
guide's fixed selector list. Honeycrisp's app menu is small (see
`AppDelegate.swift`'s manual menu construction around the `Settings…` item), so check
which of these actually appear before assuming all nine are reachable — no need to
override validation for menu items the app doesn't have.

### 1.6 Autosave window position (guide §2.6)

Not currently set. One-line addition:
`window.setFrameAutosaveName("SettingsWindow")` (or equivalent init parameter) in
`SettingsWindowController.init`.

---

## 2. Per-tab structure (guide §3, AppKit `NSTabViewController` pattern)

### 2.1 Lazy-load pane content

Today all four `loadView()`s run whenever their tab is first selected by
`NSTabViewController`'s own lazy default — this part is already fine, since
`NSTabViewController` doesn't eagerly instantiate every tab's view controller.
`SettingsTabViewController.viewDidLoad()`'s `tabSpecs` closures (`{ GeneralSettingsViewController() }` etc.)
also defer VC construction itself, not just view loading — keep that pattern.

Nothing here is actually async today (no disk/network I/O in any of the four
`loadView()`s), so `loadPaneContent(completion:)`'s async hook from the guide isn't
needed yet. Skip it unless a future pane needs it — don't add machinery with no
current caller.

### 2.2 Capture preferred size once, from layout (guide §3.2)

Needed for §1.3 above. Each of General / Appearance / History / Shortcuts needs a
`resolvePreferredPaneSize()` call at the end of `loadView()` — General and Shortcuts
build fixed-content stacks so this is straightforward; Appearance and History both
wrap their real content in an `NSScrollView`, so their "preferred size" should be a
sensible **capped** height (e.g. clamp to a max window height, let the internal
scroll view take over past that), not the full unclamped content height — otherwise
a large theme count or long history list would try to resize the window to an
enormous frame instead of scrolling.

### 2.3 Clamp pane width to the toolbar's minimum (guide §3.3)

Four tabs (General, Appearance, History, Shortcuts) — check what `NSTabViewController`'s
own toolbar imposes as minimum width at four items and clamp every pane's target
width to it before animating, to avoid the one-frame flicker the guide describes.

### 2.4 Cache per-tab sizes (guide §3.4)

Cache each tab's resolved size on first computation so tab-switching back doesn't
re-run layout resolution. Straightforward addition alongside §1.3/§2.2.

---

## 3. Layout details (guide §5)

### 3.1 Label column alignment

The guide's own comment block at the top of `AppearanceSettingsViewController`
already documents a past fix here: labels were right-aligned, got left-aligned to
match "how every other left-aligned macOS settings pane reads." General uses
checkboxes with no separate label column (not applicable). Shortcuts uses a fixed
180pt-wide label per row (`makeRow(for:)`) — left-aligned already via `NSStackView`
default, consistent with Appearance's current state. No further change needed here;
this item is really "verify consistency," which it already has.

### 3.2 Two-column grid: fixed-but-flexible width

Appearance already uses `NSGridView` with explicit `xPlacement = .leading` on both
columns (guide §5.1's AppKit-manual version of what `Form` gives SwiftUI for free).
It does not currently have the guide's two-priority-constraint pattern (`.defaultHigh`
fixed width + `.defaultLow` `≤50%` fallback) on the label column — it relies on
`NSGridView`'s own column sizing instead. Given the window won't be resizable per
§1.1, this degrade-gracefully behavior matters less than the guide implies for a
genuinely resizable pane; skip adding the two-priority constraints unless a future
pane becomes user-resizable.

### 3.3 Standard system spacing

Current code uses hardcoded pixel values throughout (`spacing = 16`, `constant: 20`,
`spacing = 12`, etc.) rather than `equalToSystemSpacingBelow`/`equalToSystemSpacingAfter`.
This is a real, mechanical gap versus the guide, and the highest-value, lowest-risk
change in this whole plan: swap fixed-constant margin/spacing constraints for the
system-spacing constructors across all four panes' `loadView()`s. Doesn't change any
control logic, only layout constants.

### 3.4 Debug wireframe overlay

Optional, dev-only. Given Honeycrisp's settings layout is already built (not being
designed from scratch), the payoff described in the guide — catching subtly-wrong
alignment during design — is lower here. Skip unless a specific alignment bug shows
up during the §1.3 resize work, at which point it's cheap to add temporarily.

### 3.5 "Settings" vs "Preferences" naming

Honeycrisp targets current macOS only (no indication of supporting pre-Ventura OS
versions in `AppDelegate.swift` — the `Settings…` menu item and `⌘,` are hardcoded
already). Skip the OS-version-derived label switch; "Settings" is correct and fixed.

---

## 4. Accessibility (guide §6)

- **Reduce Motion**: covered by §1.3 above.
- **Decorative images**: `ThemeBigSwatchButton`'s rendered "Aa" swatch image and the
  add-theme "+" tile's `NSImageView` are both decorative relative to their adjacent
  text (the swatch already sets `setAccessibilityLabel(theme.name)` on the button
  itself, and the add tile sets `"Add a new theme"` on the button) — the *icon
  subviews inside* those buttons should get `setAccessibilityElement(false)` so
  VoiceOver reads the button's label once, not the button label plus a redundant
  image description. Check `plus` (`NSImageView` in `makeAddThemeTile`) specifically;
  it currently has no accessibility settings of its own.
- **Localization**: out of scope — Honeycrisp has no localization infrastructure
  visible in this repo (`tabSpecs` labels are literal strings, not keys). Not adding
  a localization layer as part of this pass; note it as a separate future project if
  ever needed, since retrofitting §6's "resolve at display time" pattern onto four
  hardcoded tab labels plus every pane's field labels is a much larger job than
  everything else in this plan combined.

---

## 5. Explicitly out of scope

- **Sidebar design (guide's architecture B)**: not applicable — four flat,
  unrelated categories with no sub-navigation is exactly the guide's stated case for
  tab bar over sidebar (§1). Don't introduce `NavigationSplitView`/SwiftUI.
- **SettingsKit-style declarative tabs/subtabs (guide §4)**: Honeycrisp has no
  per-tab sub-navigation (no "Accounts"-style list-of-many), so subtabs, `.top{}`/
  `.bottom{}` slots, and `ToolbarGroup` actions don't map onto anything here. Skip
  section 4 of the guide entirely.
- **`SettingsLink` deep-linking (guide §4.5)**: `AppDelegate.openSettingsAction(_:)`
  already opens `SettingsWindowController.shared` directly via a plain `NSMenuItem`
  action, not the `NSApp.sendAction(Selector(("showSettingsWindow:")))` pattern the
  guide warns about — nothing to change here, and there's no in-app "Open Settings"
  button elsewhere that would need `SettingsLink`.
- **Rewriting Appearance's theme grid/inline editor**: substantial, already-working,
  already-documented-with-rationale (see the file's own header comment block on past
  iterations). This plan changes only its outer sizing/spacing, not its internal
  design.

---

## 6. Suggested implementation order (original pass)

1. §3.3 (system spacing) — mechanical, zero behavior risk, do first.
2. §1.4 + §1.6 (title sync, frame autosave) — small, independent additions.
3. §1.5 (menu item validation) — small, independent, needs a check of the actual
   app-menu contents first.
4. §2.2 + §1.3 (preferred-size capture, animated resize, top-left anchor,
   Reduce Motion) — the core structural change; do together since §1.3 depends on
   §2.2's per-pane sizes.
5. §1.1 (style mask / resizable-per-pane) — do after §1.3 works, since removing
   `.resizable` from the base mask makes the old fixed-size window meaningless until
   the animated resize path is in place.
6. §2.3 + §2.4 (toolbar-width clamp, per-tab size cache) — polish once the base
   resize mechanism is verified working across all four tabs.
7. §4 (accessibility) — the `plus` image-view fix, done as a small follow-up pass.

## 7. Follow-up pass (post-review fixes and additions)

Feedback after the first implementation: the window sized *smaller* than
before and clipped text/scrolling content, and the tab selectors hadn't
visibly changed. Root causes and fixes:

- **Tab selectors unchanged**: `SettingsTabViewController` never set
  `tabStyle`. Default is `.segmentedControlOnTop` (small pill control);
  `.toolbar` is what actually produces the large icon+label buttons this plan
  called "the classic pre-Ventura look" in §1. Confirmed against the
  reference (`macosappsettings.xml`): `tabStyle = .toolbar` paired with
  `window?.toolbarStyle = .preference` and `titlebarSeparatorStyle = .automatic`.
  All three added.
- **General tab clipped text**: `stack.fittingSize` (used to measure the
  stale-200pt root's real height) ignores externally-imposed width
  constraints — it runs its own internal layout pass on the stack in
  isolation. The wrapping hint `NSTextField`s were therefore computing their
  fitting height against an unconstrained natural width instead of the real
  ~480pt content width, undercounting height. Fixed by pinning an explicit
  `widthAnchor` on the stack before layout and reading the stack's real
  resolved `frame.height` afterward instead of `fittingSize`.
- **Appearance/History felt smaller than before**: not a regression in the
  scroll-view panes themselves, but their designed heights (480pt / 320pt)
  were already tight before this whole pass even started. Bumped to 560pt /
  380pt so less of each needs to hide behind the internal scroll view.
- **Toolbar-width clamp (§2.3)**: was a hardcoded 520pt guess. Replaced with
  a measurement of the toolbar's actual `contentLayoutRect.width`, captured
  once after the window is first visible, matching the reference's
  `minimumContentWidth`/`clampsToToolbarMinimumWidth` pattern.

Also added, per direct request (not from the original guide):

- **"Reset All to Defaults" button** (General tab, bottom, confirmation
  alert): backed by a new `SettingsManager.resetAllToDefaults()` that covers
  every tab -- General's behaviour flags, the existing
  `resetReaderToDefaults()` (Appearance's themes + link-clicks flag), and
  every keyboard shortcut back to `RebindableAction.defaultBinding`. History
  entries are explicitly untouched. Shortcuts now observes
  `.keyBindingsChanged` so it doesn't show stale bindings if already loaded
  when the reset fires from General; Appearance has a known gap here (see
  code comment at the call site) since its own reappearance-refresh only
  triggers on a theme *selection* change, not a same-theme content reset --
  left as a follow-up rather than reworked in this pass.
- **"Allow link clicks" default flipped to on**: this flag is a blanket CSS
  `pointer-events` toggle, so it was also silently disabling external
  http/https links (which `ReaderViewController`'s `WKNavigationDelegate`
  opens via `NSWorkspace.shared.open`, i.e. the user's default browser), not
  just internal cross-references as the old hint text implied. Default
  changed to on, `resetReaderToDefaults()` and `isReaderCustomized` updated
  to match, hint text rewritten to describe both link kinds.

---
