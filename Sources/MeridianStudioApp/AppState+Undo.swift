// Sources/MeridianStudioApp/AppState+Undo.swift
import AppKit
import ProjectModel

extension AppState {
    /// Disabled while recording: `stopRecording()`/`stopAudioRecording()` read
    /// `selectedTrackIndex` at Stop time, and undoing a track change mid-take
    /// would file the take on the wrong track — the same hazard
    /// `selectTrack(at:)`/`removeTrack(at:)` already guard against.
    var canUndo: Bool {
        if let fieldEditor = activeFieldEditor { return fieldEditor.undoManager?.canUndo ?? false }
        return !isRecording && document.undoManager.canUndo
    }
    var canRedo: Bool {
        if let fieldEditor = activeFieldEditor { return fieldEditor.undoManager?.canRedo ?? false }
        return !isRecording && document.undoManager.canRedo
    }

    func undo() {
        if let fieldEditor = activeFieldEditor {
            fieldEditor.undoManager?.undo()
            return
        }
        guard canUndo else { return }
        document.undoManager.undo()
        reconcileSelectionAfterUndo()
    }

    func redo() {
        if let fieldEditor = activeFieldEditor {
            fieldEditor.undoManager?.redo()
            return
        }
        guard canRedo else { return }
        document.undoManager.redo()
        reconcileSelectionAfterUndo()
    }

    /// The text view currently editing a text field (e.g. the tempo field),
    /// if any. While one is active, Undo/Redo belong to the text being typed,
    /// not to the project.
    private var activeFieldEditor: NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isFieldEditor else { return nil }
        return textView
    }

    /// Undoing "add track" can remove the selected track; keep the selection
    /// pointing at a real track. `selectedNoteID` is left alone — a stale id
    /// matches nothing, which already reads as "no selection".
    private func reconcileSelectionAfterUndo() {
        let lastIndex = max(document.project.tracks.count - 1, 0)
        selectedTrackIndex = min(max(selectedTrackIndex, 0), lastIndex)
    }
}
