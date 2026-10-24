# Plan: no windows open after 730be64 (bare `@main` AppDelegate never installed)

## 1. Title and base

- Task: bug fix, not a roadmap milestone. No decision ID (R1 to R23) or milestone (M0 to M10) changes.
- Base: `main` at 730be64 (tag v3.0.1, "fix settings"). Working tree: `.git-meta/uncommitted.diff` is empty; `status.txt` lists only untracked `docs/*.md`.
- Evidence now available: the owner's `git show 730be64 -- Sources/App project.yml Sources/Reader/ReaderWindowController.swift` (section 3, fact 1).
  That command was path-limited, so other files in the commit (for example `SettingsWindowController.swift`, which has a late mtime in the zip) are still unseen.
- Reference templates (two repomix files) are reference only; see "Reference templates" below.

## 2. Goal and non-goals

Goal: launch shows one empty reader window; launch with a file shows only the book window; Dock reopen shows a window; the main menu bar and Settings (Cmd-,)
work. Add a test that fails if the delegate is not installed again.

Non-goals: no SwiftUI lifecycle, no Settings UI change, no persistence change, no `ReaderViewController` change, no new dependency, no new test target in this plan.

## 3. Facts

Verified (owner's git output, or code read at HEAD):

1. 730be64 (on the three paths shown): adds a bare `@main` line above `class AppDelegate: NSObject, NSApplicationDelegate` in `AppDelegate.swift`, and deletes
   `Sources/App/EPUBReaderApp.swift` (33 lines, the SwiftUI entry point; only its first lines were pasted). `project.yml` and `ReaderWindowController.swift`
   show no diff in that commit, so neither changed. This removes the project.yml, Info.plist and window-controller hypotheses from the earlier draft.
2. `AppDelegate` has no `static func main()`, no `init` that registers itself, and nothing in `Sources/` assigns `NSApp.delegate`
   (grep for `.delegate =` on the application finds only window, webView, toolbar and speech delegates).
3. All launch behavior lives in delegate callbacks: `applicationWillFinishLaunching` (tabbing off, appearance override, Apple-Event handler, `setupMenus()`,
   shortcut observer) and `applicationDidFinishLaunching` (opens the first window if `NSApp.windows.isEmpty`). `applicationShouldHandleReopen` opens a window on Dock click.
4. `project.yml` sets `INFOPLIST_KEY_NSPrincipalClass: NSApplication` and has no `NSMainNibFile` or `NSMainStoryboardFile`; `Honeycrisp/Info.plist` has neither.
   So no nib exists that could instantiate `AppDelegate`.
5. `ReaderWindowController` retains itself in `openWindows`; `SettingsWindowController.shared` is lazy and used only by `openSettingsAction`; nothing hides or closes reader windows at launch.
6. Hosted tests: `HoneycrispTests` uses `TEST_HOST` (the app binary) and `@testable import Honeycrisp`; CI (`tests.yml`, macos-26, Xcode 26.3) runs them. No test asserts launch behavior or `NSApp.delegate`.
   Unit tests pass without a delegate, which is why CI did not catch this.
7. `ARCHITECTURE.md` section 10 says `AppDelegate` is the direct `@main` entry "(`NSApplicationMain`)". The doc does not say how the delegate gets installed.

Unverified (cannot run macOS here):

- U1 (leading, strongly suggested by facts 2 to 4): AppKit's `@main` for an `NSApplicationDelegate` runs `NSApplicationMain`, which obtains the delegate from a main nib or storyboard only.
  With no nib, `NSApp.delegate` stays nil: `applicationWillFinishLaunching` and `applicationDidFinishLaunching` never run, so no menus from `setupMenus()`, no window, and Cmd-, does nothing.
  This matches the report and the fact that the SwiftUI shim previously installed the delegate and supplied windows. One-minute confirmation in Pass 0.
- U2: `NSApplication.delegate` is weak, so a delegate created in `main()` must be retained elsewhere (standard AppKit behavior, not read in a header here).
- U3: What the deleted shim provided besides the delegate (window scene, activation policy, Settings scene). The paste is truncated.
- U4: Whether 730be64 changed other files (path-limited output).
- U5: `@MainActor static func main()` compiles cleanly under Swift 5.9 language mode with the macOS 13 target (owner builds).
- U6 (secondary, only if U1 is refuted): the earlier hypotheses (exception swallowed in `ReaderWindowController.init`, `NSApp.windows` non-empty at launch, no activation).

## 4. Layers, contracts, invariants

- Layer L5 Shell. No FRAMEWORK contract (C1 to C5), persisted format, setting, notification or JS bridge name changes.
- CLAUDE.md invariants kept: pure AppKit, `@main` on `AppDelegate`, one window per book, Settings has one implementation.
- The fix keeps `@main` on `AppDelegate`, so it matches the entry point ARCHITECTURE section 10 already documents; it does not conflict with FRAMEWORK or a roadmap decision.
- Untested per CLAUDE.md: `ReaderViewController` and `SettingsManager`. Say so in each pass report.

### Reference templates (reference only; nothing copied)

- Template 1 ("SidebarApp") and template 2 ("MyApp") are both SwiftUI `App` lifecycles (`WindowGroup`, `Settings` scene, `MenuBarExtra`). Neither has a bare AppKit `@main` delegate,
  so neither shows the delegate-install mechanism. Template 2 uses `@NSApplicationDelegateAdaptor` where it needs a delegate, which is the mechanism the removed shim presumably used.
  That supports U1: SwiftUI instantiates and installs the delegate for you; bare AppKit `@main` does not.
- Adopting either would reintroduce SwiftUI, reversing ARCHITECTURE section 10 and the CLAUDE.md invariant. Not part of this plan (decision B1).
- Useful idea from template 2: `scripts/smoke_launch.sh` only asserts the process stays alive, which this bug would pass (process alive, no window, no menus). Its `LaunchUITests`
  asserts a window exists, which would catch it. Honeycrisp has no UI-test target; adding one is a project config change, left as decision N2.

## 5. Passes

### Pass 0: confirm (owner, no repo change, about five minutes)

1. `git show --stat 730be64` (full, all paths) and `git show 730be64^:Sources/App/EPUBReaderApp.swift` (what the shim provided: U3, U4).
2. Confirm U1 on the current build, either:
   - run in Xcode with a breakpoint at the first line of `applicationWillFinishLaunching`: if it never hits, the delegate is not installed; or
   - launch from Terminal, then in lldb `po NSApp.delegate` (expect `nil`); or
   - observe: the menu bar shows only a bare app-name menu, not File, Edit, View, Window.
3. If the breakpoint does hit, stop and return the results; U6 applies and this plan is re-issued.

Done when: U1 is confirmed or refuted. Pass 1 is safe to start without waiting if step 2 is slow: the edit is harmless when the delegate was already installed.

### Pass 1: install the delegate explicitly (the fix)

Objective: `NSApp.delegate` is an `AppDelegate` on every launch, and a test proves it.

Files and symbols:

- `Sources/App/AppDelegate.swift`: keep `@main` and add inside `AppDelegate`:
  ```swift
  /// NSApplication.delegate is weak, and a bare @main has no nib to instantiate the delegate.
  private static var retainedDelegate: AppDelegate?

  @MainActor
  static func main() {
      let app = NSApplication.shared
      let delegate = AppDelegate()
      retainedDelegate = delegate
      app.delegate = delegate
      app.setActivationPolicy(.regular)
      app.run()
  }
  ```
  No other edit to the file. Alternative considered and rejected for this pass: delete `@main` and add `Sources/App/main.swift` with the same body; equal effect, larger diff, and it would change the documented entry point.
- `Tests/HoneycrispTests/AppDelegateInstallTests.swift` (new), `@MainActor final class AppDelegateInstallTests: XCTestCase`:
  - `testApplicationDelegateIsAppDelegate` asserts `NSApp.delegate is AppDelegate`. Fails on 730be64 if U1 is true; passes after this pass. The assertion is valid only because the SwiftUI shim, which wrapped the delegate, is gone.
  Do not assert on window counts in this test: the hosted test runner may start before `applicationDidFinishLaunching` finishes (Unverified).
- Commands: `xcodegen generate`, `./test.sh`, `swiftlint Sources/App/AppDelegate.swift Tests/HoneycrispTests/AppDelegateInstallTests.swift`, then the manual list in section 8.
- Done when: owner confirms on a built app: a window on launch, the full menu bar (File, Edit, View, Reading, Window and the rest `setupMenus` builds), Cmd-, opens Settings, Cmd-N, Dock reopen, Finder double-click of an EPUB.
- Must not touch: `setupMenus`, `applicationDidFinishLaunching`, Settings, `project.yml`.
- Risk: the Finder-open path double-handles `kAEOpenDocuments` (custom handler plus `application(_:open:)`); Unverified, covered by the manual list. Rollback: revert the diff (returns to the broken state).
- Size: about 25 changed lines plus one small test file.

### Pass 2: harden the launch decision (optional; owner decides after Pass 1)

Objective: the first-window decision no longer depends on `NSApp.windows`, and activation is explicit. Only do this if Pass 1 works and the owner wants defense in depth, or if U6 applies.

- `Sources/App/LaunchWindowPolicy.swift` (new): `enum LaunchWindowPolicy { static func shouldOpenInitialWindow(readerWindowCount: Int, openRequestReceived: Bool) -> Bool }` returning `readerWindowCount == 0 && !openRequestReceived`.
- `Sources/Reader/ReaderWindowController.swift`: add `static var openCount: Int { openWindows.count }`.
- `Sources/App/AppDelegate.swift`: add `private var openRequestReceived = false`, set in `application(_:open:)` when `supportedURLs` is non-empty; in `applicationDidFinishLaunching` replace the `NSApp.windows.isEmpty` guard with the policy;
  after `showWindow(nil)` activate the app (`NSApp.activate()` under `#available(macOS 14.0, *)`, else `NSApp.activate(ignoringOtherApps: true)`); add one `os.Logger` line (subsystem `com.noliaphyta.Honeycrisp`, category `launch`) per branch.
- `Tests/HoneycrispTests/LaunchWindowPolicyTests.swift` (new): `testOpensInitialWindowWhenNoReadersAndNoOpenRequest` (0, false is true); `testDoesNotOpenInitialWindowWhenFileOpenRequested` (0, true is false);
  `testDoesNotOpenInitialWindowWhenReaderAlreadyOpen` (1, false and 3, true are false).
- Must not touch: menus, Settings, `ReaderViewController`. Risk: a second window on file launch if the open event arrives after `applicationDidFinishLaunching`; mitigated by the manual Finder test. Size: under 120 lines excluding tests.

### Pass 3: docs

- `ARCHITECTURE.md` section 10: state how the delegate is installed (explicit `main()`, no nib) and that bare `@main` does not install it; add Pass 2 behavior if done.
- `INDEX.md`: AppDelegate range note, and new files if Pass 2 ran (run `scripts/index-anchors.sh`).
- No roadmap `Status:` change.

## 6. Order and dependencies

Pass 0 (confirm) can overlap Pass 1. Pass 2 depends on Pass 1. Pass 3 follows whichever code passes ran. After each code pass: incremental `passN-slug.diff` and `combined-through-passN.diff` against the zip, each checked with `git apply --check`, per CLAUDE.md.

## 7. Decisions needed

Blocking: none. Pass 1 can start now.

Non-blocking:

- B1 (confirm, default yes): Honeycrisp stays AppKit-only; neither template's SwiftUI lifecycle is adopted.
- N1: Do Pass 2 now or only if Pass 1 does not fully fix launch.
- N2: Add a launch UI-test target (template 2 pattern) or a smoke script that asserts a window exists. Needs a `project.yml` target and automation permissions locally; not CI-trivial. Not in this plan.
- N3: Whether the original complaint "menu bar options" meant the main menu bar (assumed) or a status-bar item like the templates' `MenuBarExtra` (Honeycrisp has none; that would be a new feature needing the CLAUDE.md feature questions).
- N4: Whether to share the rest of 730be64 (`git show --stat 730be64`) to rule out other changes (U4).

## 8. Verify-before-coding list

1. Pass 0 step 2 result (delegate nil or not).
2. Contents of the deleted shim (what it provided).
3. `@MainActor static func main()` builds without new warnings on the owner's Xcode (U5).
4. After Pass 1, manual: launch with no file; double-click an EPUB with the app closed; Dock click with all windows closed; File > New Window; File > Open Recent;
   Cmd-, opens one Settings window and refocuses on repeat; Window menu lists windows; menu items validate (View, Reading, Go); quit with Cmd-Q.
5. Settings and menus are the original goal of 730be64: confirm both now work, not only that windows return.

## Out of scope, noticed (not planned)

- `ReaderViewController.loadView` registers five page-world handlers that default `FlowSurface` does not appear to use (its scripts run in `.defaultClient`). Unverified.
- `makeToolbarButton` and the font-size toolbar item force-unwrap SF Symbols.
- `AppDelegate.openDocumentAction` falls back to `NSApp.windows.first`, which can be the Settings window.
- Doc drift: `INDEX.md` AppDelegate ranges and base line, and the `README.md` architecture table.
