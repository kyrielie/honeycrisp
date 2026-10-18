# Honeycrisp Settings Window — Status and Follow-ups

This document replaces the original pre-Ventura AppKit rebuild plan. That plan
described work that has since been implemented and included a later product
decision that changed the sizing behavior again. The current implementation is
in `Sources/Settings/SettingsWindowController.swift`; see
[`ARCHITECTURE.md`](../ARCHITECTURE.md) §9 for the reason the resize machinery
is intentionally inert.

## Current behavior

- Four toolbar tabs: General, Appearance, History, and Shortcuts.
- A fixed 520×560 content size across all tabs. Appearance and History use
  internal scrolling where needed; tab changes do not visibly resize the
  window.
- Window title, Window-menu entry, and miniwindow title follow the selected tab.
- The window frame is autosaved as `SettingsWindow`.
- The size-resolution, top-left resize animation, Reduce Motion handling,
  per-pane resizability, and size cache remain implemented, but all panes
  currently report the same fixed size and none opts into user resizing.
- General includes “Reset All to Defaults.” It restores settings and key
  bindings while leaving reading history intact.
- “Allow link clicks” defaults to on, including external links.

## Follow-ups

1. Refresh Appearance when “Reset All to Defaults” fires while Appearance is
   already loaded. Its current refresh path reacts to theme selection changes,
   not a reset that retains the same selected theme.
2. Check whether the decorative image subviews in the Appearance theme swatches
   need explicit accessibility exclusion. The buttons already have accessible
   labels; avoid duplicate VoiceOver announcements.
3. Consider replacing hardcoded layout spacing with AppKit system spacing where
   it improves consistency. This is a visual polish item, not a blocker.
4. Localization remains a separate project; labels and tab names are currently
   literal strings, and the repository has no localization resources.

## Historical implementation notes

The original plan called for independently sized panes and animated resizing.
That behavior was implemented, reviewed, and then intentionally changed to a
shared fixed pane size because resizing between tabs felt distracting. The
mechanism remains in the source so it can be re-enabled if the product decision
changes. The original guide and reference artifacts mentioned in earlier drafts
are not present in this repository, so they are not treated as current sources.
