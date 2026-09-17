// Sources/MeridianStudioApp/TrackListView.swift
import SwiftUI

struct TrackListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(appState.document.project.tracks) { track in
            HStack {
                Text(track.name)
                Spacer()
                Text("\(track.regions.count) region(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
