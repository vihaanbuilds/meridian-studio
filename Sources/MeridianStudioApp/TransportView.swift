// Sources/MeridianStudioApp/TransportView.swift
import SwiftUI

struct TransportView: View {
    @EnvironmentObject var appState: AppState

    private var tempoBinding: Binding<Double> {
        Binding(
            get: { appState.document.project.tempo },
            set: { appState.document.setTempo($0) }
        )
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: { appState.play() }) {
                Image(systemName: "play.fill")
            }
            Button(action: { appState.stopPlayback() }) {
                Image(systemName: "stop.fill")
            }
            Button(action: { appState.toggleRecording() }) {
                Image(systemName: appState.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundColor(appState.isRecording ? .red : .primary)
            }
            Divider().frame(height: 20)
            HStack {
                Text("Tempo")
                TextField("Tempo", value: tempoBinding, format: .number)
                    .frame(width: 60)
            }
            Spacer()
        }
        .padding(8)
    }
}
