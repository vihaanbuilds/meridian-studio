// Sources/MeridianCompanionApp/ContentView.swift
import SwiftUI
import Charts
import ProjectModel

struct ContentView: View {
    var body: some View {
        TabView {
            SessionView()
                .tabItem { Label("Session", systemImage: "waveform") }
            TrendView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
        }
    }
}

private struct SessionView: View {
    @EnvironmentObject private var state: CompanionState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Button(action: toggleSession) {
                Text(state.isRecording ? "Stop" : "Start Session")
                    .font(.largeTitle)
                    .frame(minWidth: 240, minHeight: 100)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(state.isRecording ? "Stop session" : "Start session")

            if state.activeTrackKind == .audio {
                LevelMeterView(level: state.level)
            } else {
                Text(state.isNoteSounding ? "Note sounding" : "Ready")
                    .font(.title3)
                    .foregroundColor(state.isNoteSounding ? .accentColor : .secondary)
                    .accessibilityLabel(state.isNoteSounding ? "Note sounding" : "No note sounding")
            }

            Button("Play Last Session", action: state.playLastSession)
                .disabled(state.sessions.isEmpty || state.isRecording)
                .accessibilityLabel("Play last session")

            if let lastError = state.lastError {
                Text(lastError)
                    .foregroundColor(.red)
                    .font(.caption)
                    .accessibilityLabel("Error: \(lastError)")
            }

            Spacer()
        }
        .padding()
    }

    private func toggleSession() {
        state.isRecording ? state.stopSession() : state.startSession()
    }
}

private struct TrendView: View {
    @EnvironmentObject private var state: CompanionState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Session History")
                .font(.headline)
                .padding(.bottom, 4)
            if state.sessions.isEmpty {
                Text("No sessions recorded yet.")
                    .foregroundColor(.secondary)
            } else {
                Chart(state.sessions) { session in
                    BarMark(
                        x: .value("Date", session.date, unit: .day),
                        y: .value("Duration (s)", session.durationSeconds)
                    )
                }
                .accessibilityLabel("Session duration over time")
                .frame(minHeight: 200)
            }
        }
        .padding()
    }
}
