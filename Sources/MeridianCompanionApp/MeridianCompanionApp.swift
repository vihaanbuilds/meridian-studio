// Sources/MeridianCompanionApp/MeridianCompanionApp.swift
import AppKit
import SwiftUI

@main
struct MeridianCompanionApp: App {
    @StateObject private var state = CompanionState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 480, minHeight: 360)
        }
    }
}
