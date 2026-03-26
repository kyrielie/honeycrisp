// EPUBReaderApp.swift
// Entry point for the EPUBReader macOS application

import SwiftUI

@main
struct EPUBReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
