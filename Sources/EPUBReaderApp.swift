// EPUBReaderApp.swift
// Entry point for the EPUBReader macOS application

import SwiftUI
import AppKit

@main
struct EPUBReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // FIX: The Settings scene was showing EmptyView(), which is why the
        // settings window was always blank. SwiftUI intercepts Cmd+, and the
        // "Settings..." menu item and shows this scene — completely bypassing
        // SettingsWindowController. Replaced EmptyView with a real
        // NSViewControllerRepresentable that hosts SettingsViewController.
        Settings {
            SettingsView()
                .frame(width: 320, height: 130)
        }
    }
}

/// Bridges AppKit's SettingsViewController into the SwiftUI Settings scene.
struct SettingsView: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> SettingsViewController {
        SettingsViewController()
    }
    func updateNSViewController(_ nsViewController: SettingsViewController, context: Context) {}
}
