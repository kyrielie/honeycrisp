// EPUBReaderApp.swift
// Entry point for the EPUBReader macOS application

import SwiftUI
import AppKit

@main
struct EPUBReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Settings is the one SwiftUI Scene kind that doesn't auto-show a window
    // at launch (unlike WindowGroup), so it's the cheapest way to satisfy
    // `some Scene` for an app that's otherwise 100% AppDelegate/AppKit-driven
    // -- there is nothing else here for SwiftUI to manage.
    //
    // Deliberately empty: the app's actual Settings window is
    // SettingsWindowController.shared, opened by AppDelegate.openSettingsAction
    // via the manually-built "Settings…" menu item (see AppDelegate.setupMenus).
    // This used to instead host a second, independently-constructed
    // SettingsTabViewController here (fixed 480×400, none of
    // SettingsWindowController's toolbar-style tabs/title-sync/frame-autosave/
    // animated-resize behavior) -- a real, different Settings UI that only
    // SwiftUI's own Settings-scene command could reach, coexisting with the
    // one every user-facing path actually opens. Left empty instead of wired
    // up to anything, so there's exactly one Settings implementation in the
    // app: if this scene is ever invoked, it shows nothing rather than a
    // stale second settings window.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
