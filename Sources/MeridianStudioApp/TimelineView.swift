// Sources/MeridianStudioApp/TimelineView.swift
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let laneHeight: CGFloat = 60
    /// Ceiling on the timeline's own height (four lanes' worth). Without it the
    /// stack grew one lane per track and squeezed `PianoRollView` to nothing in a
    /// minimum-size window; lanes past the cap are reached by scrolling vertically.
    private let maxVisibleHeight: CGFloat = 240

    private var totalHeight: CGFloat {
        CGFloat(appState.document.project.tracks.count) * laneHeight
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(appState.document.project.tracks.enumerated()), id: \.element.id) { index, track in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(index == appState.selectedTrackIndex ? Color.accentColor.opacity(0.1) : Color.clear)
                        ForEach(track.regions) { region in
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.6))
                                .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                                .overlay(alignment: .topLeading) {
                                    Text("Region").font(.caption2).padding(2)
                                }
                        }
                    }
                    .frame(minWidth: 800, minHeight: laneHeight, alignment: .topLeading)
                    Divider()
                }
            }
        }
        .frame(height: min(max(80, totalHeight), maxVisibleHeight))
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
