# Undo/Redo in the App — Design

Date: 2026-10-04
Status: Approved (product-owner mode: user asked for working results over spec review)
Phase: 3 (follow-on to audio trim & split)

## 1. Scope

`ProjectDocument` already registers undo for every structural edit
(record, import, add/remove track, delete notes) and, since the trim &
split milestone, for split, trim, and MIDI note drags. None of it is
reachable: the app has no Undo/Redo commands, so Cmd-Z does nothing
(`docs/architecture.md`). This milestone makes undo work in the app.

In scope:

1. **Track-id capture.** Every undo closure in `ProjectDocument` that
   captures a track *index* captures the track's *id* instead and
   resolves it to an index when it runs. This is the precondition
   `docs/architecture.md` sets before undo may be surfaced. With strict
   LIFO undo and every structural change undoable, a stale index is hard
   to reach today, but an id is the correct identity and costs nothing.
2. **Quantize undo.** `quantizeNotes` registers one undo step restoring
   the region's pre-quantize notes. Today one click irreversibly rewrites
   a take's timing; once Cmd-Z exists, users will expect it to undo.
3. **Edit menu.** Undo (Cmd-Z) and Redo (Cmd-Shift-Z) commands replace
   the system Undo/Redo group and drive `document.undoManager`.
4. **Menu state.** Undo/Redo are disabled when there is nothing to
   undo/redo, and both are disabled while recording.
5. **Selection reconciliation.** After an undo/redo, `selectedTrackIndex`
   is clamped into range (undoing "add track" can remove the selected
   track).
6. **Tempo field.** While the tempo `TextField` is being edited (its
   field editor is first responder), Undo/Redo act on the text instead
   of the project.

Out of scope:

- Named menu items ("Undo Split Region"). Plain "Undo"/"Redo" only —
  setting action names correctly across the mutual re-registration
  pattern (where an undo's inverse re-enters a public method) risks
  mislabeling the redo item.
- Undo for mute, solo, and tempo (field toggles, never undoable in this
  project).
- Undo of the files on disk: undoing a recording removes the region, not
  its audio file (existing "never delete audio files" policy).
- Meridian Companion (no editing surface, no undo).

## 2. Track-Id Capture (`Sources/ProjectModel/ProjectDocument.swift`)

Add one internal helper:

```swift
func trackIndex(forID id: UUID) -> Int? {
    project.tracks.firstIndex(where: { $0.id == id })
}
```

Every method that registers undo with a closure capturing `trackIndex`
instead captures `let trackID = project.tracks[trackIndex].id` (read
after the existing bounds guard, before mutation) and, inside the
closure, resolves it:

```swift
undoManager.registerUndo(withTarget: self) { doc in
    MainActor.assumeIsolated {
        guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
        doc.removeRegion(id: region.id, fromTrackAt: trackIndex)
    }
}
```

Affected registrations: `addRegion`, `removeRegion`, `addAudioRegion`,
`removeAudioRegion`, `splitAudioRegion` (private overload),
`mergeAudioRegions`, `commitAudioRegionEdit`, `commitNoteEdit`,
`deleteNotes`, `restoreNotes`, and the new quantize undo. Public method
signatures do not change — callers keep passing indices.

`removeTrack`/`insertTrack` already identify the track by id; the index
they capture is the list *position* to reinsert at, which is the correct
meaning there. Unchanged.

## 3. Quantize Undo

`quantizeNotes` captures the region's notes before quantizing, applies
the quantized notes, and registers undo through a new private
`replaceNotes(_:inTrackAt:)` that sets the last region's notes and
registers its own inverse (the notes it replaced) — the same mutual
re-registration idiom as the rest of the file, so redo re-applies the
quantized notes. A quantize that changes nothing (already on grid)
registers nothing. `testQuantizeNotesIsNotUndoRegistered` is replaced by
tests asserting one undo step, undo restoring the original timing, redo
re-applying it, and the no-change no-op.

## 4. App Wiring

`AppState` (`Sources/MeridianStudioApp/AppState.swift`, or a new
`AppState+Undo.swift` extension following the existing
`AppState+AudioRecording.swift` split):

```swift
var canUndo: Bool { !isRecording && document.undoManager.canUndo }
var canRedo: Bool { !isRecording && document.undoManager.canRedo }

func undo() {
    if let fieldEditor = activeFieldEditor { fieldEditor.undoManager?.undo(); return }
    guard canUndo else { return }
    document.undoManager.undo()
    reconcileSelectionAfterUndo()
}
// redo() mirrors undo().
```

- `activeFieldEditor`: `NSApp.keyWindow?.firstResponder as? NSTextView`
  where `isFieldEditor` is true — i.e. a text field is being edited.
- `reconcileSelectionAfterUndo()`: clamps `selectedTrackIndex` to
  `0...(tracks.count - 1)`. `selectedNoteID` is left alone; a stale id
  matches nothing, which already reads as "no selection".
- **Keeping the menu current.** Menu enabled-state reads `canUndo`/
  `canRedo`. Most undo-stack changes coincide with a `@Published` model
  change, but group closing and undo/redo themselves are signalled by
  `UndoManager` notifications. In `bindDocument()` (already re-run on
  every document swap), subscribe to `NSUndoManagerDidCloseUndoGroup`,
  `NSUndoManagerDidUndoChange`, and `NSUndoManagerDidRedoChange` for the
  current `document.undoManager` and call `objectWillChange.send()`.

`MeridianStudioApp.swift` adds:

```swift
CommandGroup(replacing: .undoRedo) {
    Button("Undo") { appState.undo() }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!appState.canUndo)
    Button("Redo") { appState.redo() }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!appState.canRedo)
}
```

Undo/Redo correctly fall through to the project whenever the focused
field editor has nothing of its own to undo/redo — the field-editor
branch only takes over when that field's own undo manager reports
`canUndo`/`canRedo`.

Document swaps (`newProject`, `openProject`) create a fresh
`ProjectDocument` and therefore a fresh, empty undo history — the
expected behavior. Saving does not clear undo.

## 5. Testing

- `ProjectDocumentTests`: an id-capture test (region added to track B;
  track A, before it, removed; undo both → correct track and regions);
  quantize undo/redo/no-op tests. Existing undo tests keep passing.
- No automated tests for `AppState` or menu wiring (no app test target;
  matches project precedent).
- Manual smoke test: Cmd-Z/Cmd-Shift-Z after record, import, add/remove
  track, delete note, drag note, quantize, trim, split; menu items grey
  out correctly; disabled while recording; undoing an add-track while it
  is selected moves the selection to a valid track; Cmd-Z inside the
  tempo field undoes typing.

## 6. Non-Goals

- Named undo menu items.
- Undo for mute/solo/tempo.
- Deleting audio files on undo.
- Any Meridian Companion change.
