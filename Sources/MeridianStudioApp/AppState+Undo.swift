// Sources/MeridianStudioApp/AppState+Undo.swift
import AppKit
import ProjectModel

extension AppState {
    /// Disabled while recording: `stopRecording()`/`stopAudioRecording()` read
    /// `selectedTrackIndex` at Stop time, and undoing a track change mid-take
    /// would file the take on the wrong track — the same hazard
    /// `selectTrack(at:)`/`removeTrack(at:)` already guard against.
    var canUndo: Bool {
        if let fieldEditor = activeFieldEditor, fieldEditor.undoManager?.canUndo == true { return true }
        return !isRecording && document.undoManager.canUndo
    }
    var canRedo: Bool {
        if let fieldEditor = activeFieldEditor, fieldEditor.undoManager?.canRedo == true { return true }
        return !isRecording && document.undoManager.canRedo
    }

    func undo() {
        if let fieldEditor = activeFieldEditor, fieldEditor.undoManager?.canUndo == true {
            fieldEditor.undoManager?.undo()
            return
        }
        guard canUndo else { return }
        let selectedTrackID = document.project.tracks.indices.contains(selectedTrackIndex) ? document.project.tracks[selectedTrackIndex].id : nil
        document.undoManager.undo()
        reconcileSelection(preferring: selectedTrackID)
    }

    func redo() {
        if let fieldEditor = activeFieldEditor, fieldEditor.undoManager?.canRedo == true {
            fieldEditor.undoManager?.redo()
            return
        }
        guard canRedo else { return }
        let selectedTrackID = document.project.tracks.indices.contains(selectedTrackIndex) ? document.project.tracks[selectedTrackIndex].id : nil
        document.undoManager.redo()
        reconcileSelection(preferring: selectedTrackID)
    }

    /// The text view currently editing a text field (e.g. the tempo field),
    /// if any. While one is active, Undo/Redo belong to the text being typed,
    /// not to the project.
    private var activeFieldEditor: NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isFieldEditor else { return nil }
        return textView
    }

    /// Restores the selection to the track it pointed at before the
    /// undo/redo, by id, so a track whose *index* shifted (e.g. an earlier
    /// track was removed/restored around it) doesn't silently hand the
    /// selection to whatever track now sits at the old index. Falls back to
    /// clamping into range only when `trackID` is nil or no longer resolves
    /// — e.g. undoing a remove-track that was itself the selected track, or
    /// redoing a remove-track that removes the selected one. `selectedNoteID`
    /// is left alone — a stale id matches nothing, which already reads as
    /// "no selection".
    private func reconcileSelection(preferring trackID: UUID?) {
        if let trackID, let index = document.project.tracks.firstIndex(where: { $0.id == trackID }) {
            selectedTrackIndex = index
            return
        }
        let lastIndex = max(document.project.tracks.count - 1, 0)
        selectedTrackIndex = min(max(selectedTrackIndex, 0), lastIndex)
    }
}
