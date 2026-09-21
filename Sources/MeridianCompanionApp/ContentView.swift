// Sources/MeridianCompanionApp/ContentView.swift
import SwiftUI

/// Placeholder shell view. This target exists only to prove
/// `MeridianCompanionApp` builds and runs as its own app, sharing
/// `ProjectModel`/`AudioEngine` with `MeridianStudioApp` and nothing else —
/// see docs/superpowers/specs/2026-09-20-two-app-architecture-design.md.
/// No product design has been approved yet; this view is replaced entirely
/// once that milestone's own spec and plan exist.
struct ContentView: View {
    var body: some View {
        Text("Meridian Companion")
            .font(.title)
            .padding()
    }
}
