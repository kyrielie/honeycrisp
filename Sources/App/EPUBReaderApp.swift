// EPUBReaderApp.swift
// Entry point for the EPUBReader macOS application

import SwiftUI
import AppKit

@main
struct EPUBReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .frame(width: 480, height: 400)
        }
    }
}

/// Bridges AppKit's SettingsTabViewController into the SwiftUI Settings scene.
struct SettingsView: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> SettingsTabViewController {
        SettingsTabViewController()
    }
    func updateNSViewController(_ nsViewController: SettingsTabViewController, context: Context) {}
}
