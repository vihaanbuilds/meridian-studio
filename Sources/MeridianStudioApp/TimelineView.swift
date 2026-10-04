// Sources/MeridianStudioApp/TimelineView.swift
import AudioEngine
import ProjectModel
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let laneHeight: CGFloat = 60
    private let resizeHandleWidth: CGFloat = 6
    // Matches PianoRollView.minimumNoteLengthBeats — same floor, same reason:
    // a region/note this short is indistinguishable from zero-length and not
    // worth representing.
    private let minimumRegionLengthBeats: Double = 0.0625
    // Captured once per drag gesture (leading or trailing trim handle), the
    // same way PianoRollView's `dragStartNote` works — the pre-drag value to
    // restore if the whole gesture gets committed to undo.
    @State private var dragStartRegion: AudioRegion?
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

    // Both gestures measure translation in `.global`, matching
    // `PianoRollView`'s drag gestures exactly — same reasoning: these
    // gestures move the very view they're attached to, so a local origin
    // would shift underneath the in-flight drag.
    private func trimLeadingGesture(for region: AudioRegion, tempo: Double, trackIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartRegion ?? region
                if dragStartRegion == nil { dragStartRegion = region }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                // Dragging right (positive delta) can't shrink the region
                // below minimumRegionLengthBeats; dragging left (negative
                // delta) can't push sourceOffsetSeconds below 0 — there's no
                // audio before the file's own start.
                let maxDeltaBeats = start.lengthBeats - minimumRegionLengthBeats
                let minDeltaBeats = -Tempo.beats(forSeconds: start.sourceOffsetSeconds, tempo: tempo)
                let clampedDeltaBeats = min(max(deltaBeats, minDeltaBeats), maxDeltaBeats)
                var updated = start
                updated.startBeat = start.startBeat + clampedDeltaBeats
                updated.lengthBeats = start.lengthBeats - clampedDeltaBeats
                updated.sourceOffsetSeconds = start.sourceOffsetSeconds + Tempo.seconds(forBeats: clampedDeltaBeats, tempo: tempo)
                appState.updateAudioRegion(updated, inTrackAt: trackIndex)
            }
            .onEnded { _ in
                if let dragStartRegion { appState.commitAudioRegionEdit(from: dragStartRegion, inTrackAt: trackIndex) }
                dragStartRegion = nil
            }
    }

    // `fileDurationSeconds` is nil only on the first render before
    // `AppState+Waveforms.swift`'s loader has populated the cache — in that
    // narrow window this just doesn't clamp against the file's length yet
    // (the playback-time clamp in `PlaybackEngine` is the backstop either
    // way, matching how `waveformBands(for:)` itself already tolerates
    // returning nil on first render).
    private func trimTrailingGesture(for region: AudioRegion, tempo: Double, trackIndex: Int, fileDurationSeconds: Double?) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartRegion ?? region
                if dragStartRegion == nil { dragStartRegion = region }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                var maxLengthBeats = Double.infinity
                if let fileDurationSeconds {
                    let remainingSeconds = max(fileDurationSeconds - start.sourceOffsetSeconds, 0)
                    maxLengthBeats = Tempo.beats(forSeconds: remainingSeconds, tempo: tempo)
                }
                var updated = start
                updated.lengthBeats = min(max(start.lengthBeats + deltaBeats, minimumRegionLengthBeats), maxLengthBeats)
                appState.updateAudioRegion(updated, inTrackAt: trackIndex)
            }
            .onEnded { _ in
                if let dragStartRegion { appState.commitAudioRegionEdit(from: dragStartRegion, inTrackAt: trackIndex) }
                dragStartRegion = nil
            }
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
                                    if let bands = appState.waveformBands(for: region), let sampleRate = appState.sampleRateCache[region.fileName] {
                                        let durationSeconds = Tempo.seconds(forBeats: region.lengthBeats, tempo: appState.document.project.tempo)
                                        WaveformView(bands: bands.slice(fromSeconds: region.sourceOffsetSeconds, toSeconds: region.sourceOffsetSeconds + durationSeconds, sampleRate: sampleRate))
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    Text("Audio").font(.caption2).padding(2)
                                }
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.001))
                                        .frame(width: resizeHandleWidth, height: laneHeight)
                                        .gesture(trimLeadingGesture(for: region, tempo: appState.document.project.tempo, trackIndex: index))
                                }
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.001))
                                        .frame(width: resizeHandleWidth, height: laneHeight)
                                        .gesture(trimTrailingGesture(for: region, tempo: appState.document.project.tempo, trackIndex: index, fileDurationSeconds: appState.fileDurationSecondsCache[region.fileName]))
                                }
                                .gesture(
                                    SpatialTapGesture(count: 2)
                                        .onEnded { value in
                                            let clickedBeat = region.startBeat + Double(value.location.x / pixelsPerBeat)
                                            if clickedBeat > region.startBeat + minimumRegionLengthBeats,
                                               clickedBeat < region.startBeat + region.lengthBeats - minimumRegionLengthBeats {
                                                appState.splitAudioRegion(id: region.id, atBeat: clickedBeat, inTrackAt: index)
                                            }
                                        }
                                )
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
