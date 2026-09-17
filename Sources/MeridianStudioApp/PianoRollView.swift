// Sources/MeridianStudioApp/PianoRollView.swift
import SwiftUI
import ProjectModel

struct PianoRollView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let pixelsPerSemitone: CGFloat = 6
    private let lowestPitch: UInt8 = 36
    private let highestPitch: UInt8 = 96

    private var notes: [NoteEvent] {
        appState.document.project.tracks.first?.regions.last?.notes ?? []
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
                            y: CGFloat(Int(highestPitch) - Int(note.pitch)) * pixelsPerSemitone
                        )
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
