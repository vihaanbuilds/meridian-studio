// Sources/MeridianStudioApp/PianoRollView.swift
import SwiftUI
import ProjectModel

struct PianoRollView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let pixelsPerSemitone: CGFloat = 6
    private let lowestPitch: UInt8 = 36
    private let highestPitch: UInt8 = 96
    private let liveIndicatorWidth: CGFloat = 24

    private var notes: [NoteEvent] {
        guard appState.document.project.tracks.indices.contains(appState.selectedTrackIndex) else { return [] }
        return appState.document.project.tracks[appState.selectedTrackIndex].regions.last?.notes ?? []
    }

    /// Pitches currently held on the MIDI keyboard, sorted so the view has a stable
    /// `ForEach` identity. These are not part of the project yet — they are the
    /// immediate "this key is down right now" feedback.
    private var heldPitches: [UInt8] {
        appState.liveNotes.keys.sorted()
    }

    private func yOffset(forPitch pitch: UInt8) -> CGFloat {
        CGFloat(Int(highestPitch) - Int(pitch)) * pixelsPerSemitone
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Rectangle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: max(CGFloat(note.lengthBeats) * pixelsPerBeat, 4), height: pixelsPerSemitone)
                        .offset(
                            x: CGFloat(note.startBeat) * pixelsPerBeat,
                            y: yOffset(forPitch: note.pitch)
                        )
                }

                // Live input: one highlighted bar pinned to the left edge per held
                // pitch, so pressing a key is visible immediately whether or not a
                // take is running.
                ForEach(heldPitches, id: \.self) { pitch in
                    Rectangle()
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: liveIndicatorWidth, height: pixelsPerSemitone)
                        .offset(x: 0, y: yOffset(forPitch: pitch))
                }
            }
            .frame(
                width: 800,
                height: CGFloat(highestPitch - lowestPitch) * pixelsPerSemitone,
                alignment: .topLeading
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
