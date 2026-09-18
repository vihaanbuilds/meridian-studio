# Note-Level Piano Roll Editing — Design

Date: 2026-09-18
Status: Approved
Phase: 2 (second milestone)

## 1. Scope

Right now a recorded take is frozen: `NoteEvent`s exist only as
read-only display data in `PianoRollView`. There is no way to fix a
wrong note, nudge timing, or remove a stray note without re-recording
the entire region. This milestone adds:

- Select a single note by tapping it.
- Move a selected note (drag: horizontal = time, vertical = pitch).
- Resize a selected note's length (drag its right edge).
- Delete a selected note.

Out of scope, explicitly deferred (same decomposition approach as
every prior milestone): multi-select (shift-click, marquee/rectangle
select), copy/paste, quantization (a natural follow-on once notes are
selectable/movable, but a separate slice), undo/redo surfaced in the
UI for these edits (matches the project's existing, already-documented
undo-UI deferral).

## 2. Data Model Change: `NoteEvent` Gains a Stable Identity

`NoteEvent` currently has no `id` — editing or deleting one specific
note among several with possibly-identical field values has no reliable
way to address "this exact note." Add one:

```swift
public struct NoteEvent: Codable, Equatable, Sendable {
    public var id: UUID
    public var pitch: UInt8
    public var velocity: UInt8
    public var startBeat: Double
    public var lengthBeats: Double

    public init(id: UUID = UUID(), pitch: UInt8, velocity: UInt8, startBeat: Double, lengthBeats: Double) {
        self.id = id
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }
}
```

Two consequences that need explicit, deliberate handling:

**Equality must ignore `id`.** Every existing test across
`MIDIRecorderTests`, `RecordAndPersistIntegrationTests`, and
`CodableRoundTripTests` compares `NoteEvent`s by musical content
(pitch/velocity/startBeat/lengthBeats), constructing an "expected" value
that was never the same instance as the "actual" one. Synthesized
`Equatable` would include `id` and break every one of those comparisons
(two independently-constructed notes with identical musical content
would no longer compare equal). Fix: a manual `==` that compares only
the four musical fields, never `id`. `id` exists purely so the piano
roll can address a specific note; it is not part of a note's musical
identity.

**Decoding must tolerate old files that predate `id`.** A synthesized
`Decodable` would require `id` to be present in every note's JSON,
which breaks opening any `.mstudio` project saved before this
milestone (per the project's standing principle: preserve project-file
backward compatibility whenever practical). Fix: a custom
`init(from:)` that decodes `id` with `decodeIfPresent`, falling back to
a freshly generated `UUID()` when absent. `encode(to:)` stays
synthesized (via an explicit `CodingKeys` covering all five fields) —
newly saved files always include `id`; only reading old files needs the
fallback.

No other file changes because of this: `MIDIRecorder.handle` already
constructs `NoteEvent(pitch:velocity:startBeat:lengthBeats:)` without an
`id:` argument, so it picks up a fresh, unique id automatically via the
new default parameter.

## 3. `ProjectDocument` — Note Mutation

Mirrors the project's existing split: in-place field edits are not
undo-registered (matches `setTempo`, `setTrackMuted`); removing an
entity is undo-registered (matches `removeRegion`, `removeTrack`). Both
operate on a track's *current* region — `regions.last`, the same
"only the most recent region matters for display/playback" convention
already used everywhere else in the app (`PianoRollView`, `AppState.play()`).

```swift
public func updateNote(_ note: NoteEvent, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
    guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == note.id }) else { return }
    project.tracks[trackIndex].regions[regionIndex].notes[noteIndex] = note
}

public func deleteNotes(ids: Set<UUID>, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
    let removedNotes = project.tracks[trackIndex].regions[regionIndex].notes.filter { ids.contains($0.id) }
    guard !removedNotes.isEmpty else { return }
    project.tracks[trackIndex].regions[regionIndex].notes.removeAll { ids.contains($0.id) }
    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.restoreNotes(removedNotes, inTrackAt: trackIndex)
        }
    }
}

private func restoreNotes(_ notes: [NoteEvent], inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
    project.tracks[trackIndex].regions[regionIndex].notes.append(contentsOf: notes)
    let ids = Set(notes.map(\.id))
    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.deleteNotes(ids: ids, inTrackAt: trackIndex)
        }
    }
}
```

`deleteNotes` takes a `Set<UUID>` (not a single id) so the model already
supports deleting several notes at once even though this milestone's UI
only ever selects one — no rework needed when multi-select lands later.
The `registerUndo` closures use `MainActor.assumeIsolated`, matching the
pattern already established (and required — CI caught the alternative
failing) for every other undo closure in this file.

## 4. `AppState` — Selection State

```swift
@Published var selectedNoteID: UUID?
```

A single optional id, not a set — this milestone's UI only ever selects
one note. Methods:

- `selectNote(id: UUID?)` — sets `selectedNoteID` (passing `nil`
  deselects).
- `moveOrResizeSelectedNote(to updated: NoteEvent)` — calls
  `document.updateNote(updated, inTrackAt: selectedTrackIndex)`.
- `deleteSelectedNote()` — if `selectedNoteID` is set, calls
  `document.deleteNotes(ids: [selectedNoteID!], inTrackAt:
  selectedTrackIndex)` and clears the selection.

Selection is deliberately *not* cleared when `selectedTrackIndex`
changes or a document is swapped in this milestone — `selectedNoteID`
naturally stops matching anything once the underlying note is gone
(the view's lookup already has to handle "selected id no longer
exists" for the delete-then-still-selected case anyway), so no extra
bookkeeping is needed. `PianoRollView`'s notes always come from
whichever track is currently selected, so switching tracks simply shows
a different set of notes with the old selection matching none of them
— visually equivalent to deselecting, without needing to duplicate the
reset logic `bindDocument()` already owns for `selectedTrackIndex`.

## 5. `PianoRollView` — Interaction

Coordinate math, using the view's existing `pixelsPerBeat` (40) and
`pixelsPerSemitone` (6) constants:

- **Tap** a note rectangle → `appState.selectNote(id: note.id)`. Tap
  empty space → `appState.selectNote(id: nil)`.
- **Move** (`DragGesture` on the note body): capture the note's values
  at drag start; on each change, compute
  `newStartBeat = max(startBeatAtDragStart + translation.width / pixelsPerBeat, 0)`
  and `newPitch = clamp(pitchAtDragStart - Int(round(translation.height / pixelsPerSemitone)), 0, 127)`
  (subtracting, not adding, because the view's existing `yOffset`
  formula places higher pitches at smaller y — dragging down must
  decrease pitch), and call `moveOrResizeSelectedNote` with the updated
  `NoteEvent`.
- **Resize** (`DragGesture` on a narrow handle at the note's right
  edge): capture `lengthBeats` at drag start; on each change, compute
  `newLength = max(lengthAtDragStart + translation.width / pixelsPerBeat, 0.0625)`
  (a sixteenth-beat floor, preventing zero/negative length), leaving
  `startBeat`/`pitch` untouched.
- **Delete**: `.onDeleteCommand { appState.deleteSelectedNote() }` on
  the piano roll's scroll container — standard macOS idiom (select,
  press Delete/Backspace).

A selected note gets a visibly different fill/border (e.g. an accent
outline) so the user can see what's selected.

## 6. Testing

- `NoteEventTests` (new, `ProjectModelTests`): equality ignores `id`
  (two notes with identical musical fields but different explicit ids
  compare equal); decoding a JSON literal without an `id` key succeeds
  and synthesizes one; decoding a JSON literal *with* an `id` key
  round-trips that exact id.
- `ProjectDocumentTests`: `updateNote` replaces the matching note's
  values, leaves others untouched, and is *not* undo-registered
  (`undoManager.undo()` after a call does nothing testable via the
  model, since nothing was registered); `deleteNotes` removes the
  matching notes and undo restores them exactly (redo removes them
  again) — mirrors the existing `addRegion`/`removeRegion` undo/redo
  test style.
- `PianoRollView`'s gesture math: no automated tests (SwiftUI gesture
  handling has no test harness in this project, matching every prior
  UI task's precedent) — verified by build and the manual smoke test.

## 7. Non-Goals / Explicit Deferrals

- Multi-select (shift-click, marquee select).
- Copy/paste.
- Quantization.
- Undo/redo surfaced in the UI (pre-existing, already-documented
  deferral — this milestone's `deleteNotes` undo-registration is
  exercised only by unit tests, same as every other undo-registered
  operation in this codebase today).
- Editing a region other than a track's current (`regions.last`) one.
