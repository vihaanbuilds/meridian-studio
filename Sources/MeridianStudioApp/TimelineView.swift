// Sources/MeridianStudioApp/TimelineView.swift
import AudioEngine
import ProjectModel
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

    /// The furthest beat any region on this track reaches. `.offset()` is
    /// layout-transparent — it shifts what's rendered but doesn't grow a
    /// view's reported size — so a lane's own `.frame(minWidth:)` must be
    /// sized against this explicitly, or a region offset past the constant
    /// floor renders outside the ScrollView's content extent and can't be
    /// scrolled to.
    private func maxEndBeat(for track: Track) -> Double {
        let midiEnd = track.regions.map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        let audioEnd = track.audioRegions.map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        return max(midiEnd, audioEnd)
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
                                .overlay(alignment: .topLeading) {
                                    Text("Region").font(.caption2).padding(2)
                                }
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                        }
                        ForEach(track.audioRegions) { region in
                            Rectangle()
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
                                .overlay {
                                    if let peaks = appState.waveformPeaks(for: region) {
                                        WaveformView(peaks: peaks)
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    Text("Audio").font(.caption2).padding(2)
                                }
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                        }
                    }
                    .frame(minWidth: max(800, CGFloat(maxEndBeat(for: track)) * pixelsPerBeat), minHeight: laneHeight, alignment: .topLeading)
                    Divider()
                }
            }
        }
        .frame(height: min(max(80, totalHeight), maxVisibleHeight))
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
