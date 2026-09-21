// Sources/MeridianCompanionApp/MeridianCompanionApp.swift
import AppKit
import SwiftUI

@main
struct MeridianCompanionApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 480, minHeight: 360)
        }
    }
}
