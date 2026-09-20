// Sources/MeridianStudioApp/PianoRollView.swift
import SwiftUI
import ProjectModel

struct PianoRollView: View {
    @EnvironmentObject var appState: AppState
    @State private var dragStartNote: NoteEvent?
    // TrackListView is a `List` (NSTableView-backed), which takes first responder
    // when clicked. In the natural workflow — click a track, click a note, press
    // Delete — nothing here would otherwise claim keyboard focus, so
    // `.onDeleteCommand` may never fire. Tapping a note moves focus to the roll.
    @FocusState private var isFocused: Bool

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

    // Clamp to the pitches the canvas actually renders, not the full MIDI range:
    // a note dragged outside 36...96 is invisible, unreachable by scrolling (the
    // scrollable content size is fixed) and unrecoverable, since `updateNote`
    // isn't undo-registered.
    private func clampPitch(_ pitch: Int) -> UInt8 {
        UInt8(min(max(pitch, Int(lowestPitch)), Int(highestPitch)))
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
        .focusable()
        .focused($isFocused)
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
            .contentShape(Rectangle())
            .onTapGesture {
                appState.selectNote(id: note.id)
                isFocused = true
            }
            .gesture(moveGesture(for: note))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: resizeHandleWidth, height: pixelsPerSemitone)
                    .gesture(resizeGesture(for: note))
            }
            // `.offset` must come LAST. It is layout-transparent: any modifier
            // applied after it (overlay/background/border) is positioned against
            // the note's ORIGINAL, un-offset frame, not the shifted one. With the
            // offset applied earlier, the trailing resize handle rendered at the
            // top-left of the piano roll instead of on the note. Applying the
            // offset outermost puts the handle inside the shifted subtree, so it
            // tracks the note — and it still needs no `.offset` of its own.
            .offset(x: CGFloat(note.startBeat) * pixelsPerBeat, y: yOffset(forPitch: note.pitch))
    }

    // Both drag gestures measure translation in `.global` rather than the default
    // `.local` space. These gestures move the very view they are attached to, so a
    // local origin would shift underneath the in-flight drag; a stable space keeps
    // `translation` a true cursor delta, which is exactly what the beat/semitone
    // math below wants. The piano roll is unscaled, so global and local pixels are
    // the same size.
    private func moveGesture(for note: NoteEvent) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartNote ?? note
                if dragStartNote == nil { dragStartNote = note }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                let deltaPitch = -Int((value.translation.height / pixelsPerSemitone).rounded())
                var updated = start
                // Keep the note's right edge within the canvas (800pt / pixelsPerBeat
                // = 20 beats) — past that it becomes invisible, unreachable by
                // scrolling (the scrollable content size is fixed), and unrecoverable
                // since updateNote isn't undo-registered.
                let maxStartBeat = max(800 / Double(pixelsPerBeat) - start.lengthBeats, 0)
                updated.startBeat = min(max(start.startBeat + deltaBeats, 0), maxStartBeat)
                updated.pitch = clampPitch(Int(start.pitch) + deltaPitch)
                appState.selectNote(id: note.id)
                appState.moveOrResizeSelectedNote(to: updated)
            }
            .onEnded { _ in
                dragStartNote = nil
            }
    }

    private func resizeGesture(for note: NoteEvent) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
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
