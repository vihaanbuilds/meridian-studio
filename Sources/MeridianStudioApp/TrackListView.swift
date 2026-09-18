// Sources/MeridianStudioApp/TrackListView.swift
import SwiftUI

struct TrackListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tracks").font(.headline)
                Spacer()
                Button(action: { appState.addTrack() }) {
                    Image(systemName: "plus")
                }
            }
            .padding(8)

            List {
                ForEach(Array(appState.document.project.tracks.enumerated()), id: \.element.id) { index, track in
                    HStack {
                        Text(track.name)
                        Spacer()
                        Text("\(track.regions.count) region(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(action: { appState.toggleMute(at: index) }) {
                            Text("M")
                                .foregroundColor(track.muted ? .red : .secondary)
                        }
                        .buttonStyle(.borderless)
                        Button(action: { appState.toggleSolo(at: index) }) {
                            Text("S")
                                .foregroundColor(track.solo ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        Button(action: { appState.removeTrack(at: index) }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(appState.document.project.tracks.count <= 1)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .background(index == appState.selectedTrackIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                    .onTapGesture {
                        appState.selectTrack(at: index)
                    }
                }
            }
        }
    }
}
