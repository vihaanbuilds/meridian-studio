// Sources/MeridianStudioApp/PianoRollView.swift
import SwiftUI
import ProjectModel

struct PianoRollView: View {
    @EnvironmentObject var appState: AppState
    @State private var dragStartNote: NoteEvent?

    private let pixelsPerBeat: CGFloat = 40
    private let pixelsPerSemitone: CGFloat = 6
    private let lowestPitch: UInt8 = 36
    private let highestPitch: UInt8 = 96
    private let liveIndicatorWidth: CGFloat = 24
    private let resizeHandleWidth: CGFloat = 6
    private let minimumNoteLengthBeats: Double = 0.0625

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

    private func clampPitch(_ pitch: Int) -> UInt8 {
        UInt8(min(max(pitch, 0), 127))
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(
                        width: 800,
                        height: CGFloat(highestPitch - lowestPitch) * pixelsPerSemitone
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.selectNote(id: nil)
                    }

                ForEach(notes) { note in
                    noteRectangle(for: note)
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
        .onDeleteCommand {
            appState.deleteSelectedNote()
        }
    }

    private func noteRectangle(for note: NoteEvent) -> some View {
        let isSelected = appState.selectedNoteID == note.id
        let width = max(CGFloat(note.lengthBeats) * pixelsPerBeat, 4)

        return Rectangle()
            .fill(isSelected ? Color.accentColor : Color.green.opacity(0.8))
            .overlay {
                if isSelected {
                    Rectangle().stroke(Color.white, lineWidth: 1)
                }
            }
            .frame(width: width, height: pixelsPerSemitone)
            .offset(x: CGFloat(note.startBeat) * pixelsPerBeat, y: yOffset(forPitch: note.pitch))
            .contentShape(Rectangle())
            .onTapGesture {
                appState.selectNote(id: note.id)
            }
            .gesture(moveGesture(for: note))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: resizeHandleWidth, height: pixelsPerSemitone)
                    .gesture(resizeGesture(for: note))
            }
    }

    private func moveGesture(for note: NoteEvent) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStartNote ?? note
                if dragStartNote == nil { dragStartNote = note }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                let deltaPitch = -Int((value.translation.height / pixelsPerSemitone).rounded())
                var updated = start
                updated.startBeat = max(start.startBeat + deltaBeats, 0)
                updated.pitch = clampPitch(Int(start.pitch) + deltaPitch)
                appState.selectNote(id: note.id)
                appState.moveOrResizeSelectedNote(to: updated)
            }
            .onEnded { _ in
                dragStartNote = nil
            }
    }

    private func resizeGesture(for note: NoteEvent) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStartNote ?? note
                if dragStartNote == nil { dragStartNote = note }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                var updated = start
                updated.lengthBeats = max(start.lengthBeats + deltaBeats, minimumNoteLengthBeats)
                appState.selectNote(id: note.id)
                appState.moveOrResizeSelectedNote(to: updated)
            }
            .onEnded { _ in
                dragStartNote = nil
            }
    }
}
