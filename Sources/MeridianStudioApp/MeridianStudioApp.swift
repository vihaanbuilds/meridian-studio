// Sources/MeridianStudioApp/MeridianStudioApp.swift
import AppKit
import SwiftUI

@main
struct MeridianStudioApp: App {
    @StateObject private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { appState.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!appState.canUndo)
                Button("Redo") { appState.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!appState.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { appState.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { appState.openProject() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save") { appState.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { appState.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Import Audio…") { appState.importAudio() }
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}
