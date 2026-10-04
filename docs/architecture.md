# Architecture

Meridian Studio is a macOS-native DAW built in layers, mirroring the
separation described in the Phase 0 design spec
(`docs/superpowers/specs/2026-09-16-meridian-studio-design.md`):

- **UI** (`Sources/MeridianStudioApp`) — SwiftUI views: transport,
  track list, timeline, piano roll. Depends on `ProjectModel` and
  `AudioEngine`, never the other way around.
- **Project Model** (`Sources/ProjectModel`) — `Project`, `Track`,
  `MIDIRegion`, `NoteEvent` value types (Codable, UI-independent),
  `ProjectStore` (versioned JSON persistence), and `ProjectDocument`
  (an `UndoManager`-backed observable wrapper). No SwiftUI import.
- **Audio Engine** (`Sources/AudioEngine`, renamed from `MIDIEngine`
  once it grew a non-MIDI real-time I/O path — see the audio recording
  section below) — `CoreMIDIInput` (hardware
  adapter), `MIDIEventQueue` (thread-safe handoff off the CoreMIDI
  callback thread), `MIDIMessageParser`/`MIDIRecorder` (pure,
  unit-tested note-pairing logic), and `PlaybackEngine`/
  `PlaybackScheduler` (AVAudioEngine-based playback).

As of the two-app architecture
(`docs/superpowers/specs/2026-09-20-two-app-architecture-design.md`),
`ProjectModel` and `AudioEngine` are the entire foundation for a second
app, `MeridianCompanionApp` (see `docs/companion.md`) — not just
`MeridianStudioApp`. Neither app imports the other; this is enforced by
`Package.swift` simply never listing that dependency.

Undo/redo: `ProjectDocument` owns an `UndoManager`, and two tiers of
operation register with it. The first tier —
`addRegion`/`removeRegion`/`addTrack`/`removeTrack`/`addAudioRegion`/
`removeAudioRegion`/`deleteNotes`, plus `splitAudioRegion` and
`quantizeNotes` — registers one undo step on the call that mutates. The
second tier covers edits that happen gradually across a drag: a cheap
`update…` setter (`updateNote`/`updateAudioRegion`) with *no* undo
registration runs on every `onChanged` frame, and a single
`commit…Edit` call (`commitNoteEdit`/`commitAudioRegionEdit`) at
gesture-end registers the one undo step that restores the pre-gesture
value. Every undo closure captures the affected track's `id` and
resolves it to an index when it runs, so a track whose index shifted in
between (an earlier track was removed) is still the one targeted.

The Edit menu's Undo (Cmd-Z) and Redo (Cmd-Shift-Z) drive this
`UndoManager` through `AppState.undo()`/`redo()`
(`AppState+Undo.swift`). Project undo/redo are both disabled while
recording (the field-editor branch below is unaffected by recording
state). While a text field is being edited and its own undo manager has
something to undo/redo, they act on that field's text instead.
After a project undo/redo, `selectedTrackIndex` is clamped back into
range. `AppState` republishes on `UndoManager` notifications so the
menu's enabled-state stays current. Mute, solo, and tempo are not
undoable. Undoing a recording removes the region but not its audio file.

Multi-track support (Phase 2): `addTrack`/`removeTrack` are
undo-registered structural operations, matching `addRegion`/
`removeRegion`; `setTrackMuted`/`setTrackSolo` are direct field
mutations with no undo registration, matching `setTempo`. (Undo was
reserved for structural add/remove exclusively at the time this
paragraph was first written; the `update…`/`commit…Edit` tier described
above later extended it to field edits too — `setTrackMuted`/
`setTrackSolo`/`setTempo` simply haven't been given that treatment,
not because field edits are undo-exempt in general.)
`TrackAudibility.audibleTracks(in:)` implements the
standard DAW convention: if any track is soloed, only soloed tracks are
audible (solo overrides mute on the same track); otherwise every
non-muted track is audible. `AppState.selectedTrackIndex` is the track
armed for recording and shown in the piano roll — playback plays every
audible track's most recent region simultaneously, not just the
selected one.

Note-level editing (Phase 2): `NoteEvent` carries a stable `id` (added
after Phase 1 shipped, with a custom decoder that synthesizes one for
project files saved before this field existed, and an `==` that
ignores `id` so every pre-existing content-based test kept working
unmodified). `ProjectDocument.updateNote` is a field edit (no undo,
matching `setTempo`); `deleteNotes` is a structural removal
(undo-registered, matching `removeRegion`/`removeTrack` — including the
same `MainActor.assumeIsolated` bridge in its undo closure).
`AppState.selectedNoteID` tracks a single selected note; the piano roll
turns drag gestures into `updateNote` calls (move changes
`startBeat`/`pitch`, resize changes only `lengthBeats`) and `Delete`/
`Backspace` into a `deleteNotes` call.

Quantization (Phase 2, the last piece of "Full MIDI editing"):
`Quantizer.quantize(_:gridBeats:strength:maxStartBeat:)` is pure logic in
`ProjectModel` — for each note, it moves `startBeat` toward the nearest
grid line by `strength` (0...1, clamped, with a non-finite value treated
as 0 for the same NaN reason `setTempo` documents; 0 = no change, 1 = a
hard snap), leaving every other field untouched. `maxStartBeat` is an
optional upper bound on where a note may end, defaulting to no bound:
the UI layer passes `PianoRollView.canvasBeats` so quantizing cannot
push a *reachable* note off the canvas any more than dragging can,
while `ProjectModel` itself keeps no canvas constants. The bound only
holds notes that already start inside it — a note already past it (the
normal state of anything more than ~10s into a take, since the
recorder places notes with no upper bound on `startBeat`) is left
alone rather than dragged back, which would otherwise stack an entire
take's tail onto one beat with no undo to recover it.
`ProjectDocument.quantizeNotes` applies it to a track's current region
and, like `updateNote`, is a field edit with no undo registration — a
batch position edit is conceptually many field edits, not a removal.
It operates on the whole region rather than a selection, since
multi-select doesn't exist yet.

Real-time safety: the CoreMIDI read callback only parses bytes and
pushes onto `MIDIEventQueue` (allocation-free after construction,
guarded by `OSAllocatedUnfairLock`, drops events rather than blocking
when full). All project-model mutation happens on the main actor, off
that callback thread.

Audio recording & playback (Phase 3, first milestone): `TrackKind.audio`
and `AudioRegion` extend the data model the same way multi-track and
note-level editing did — `Track.audioRegions` decodes to `[]` for any
project file saved before this field existed, the same
`decodeIfPresent` pattern `NoteEvent.id` established. `AudioRegion`
stores only a filename, never an absolute path, so a project bundle can
move on disk without breaking it; the app layer resolves it against the
bundle's `audio/` directory. `ProjectDocument.addAudioRegion`/
`removeAudioRegion` are undo-registered structural operations, mirroring
`addRegion`/`removeRegion` exactly. Recording onto an audio track
requires the project to already be saved — audio data is too large to
hold as an in-memory value the way MIDI notes are, and an unsaved
project has nowhere on disk to write a file, so this milestone defers
the temporary-file staging a "record before saving" experience would
need, the same "leave the adjacent complexity for later" call this
project has made repeatedly. See `docs/audio.md` for the audio engine's
real-time-safety tradeoffs, mirroring `docs/midi.md`'s role for MIDI.

There is no mixer or AI layer yet — see the roadmap in the Phase 0 spec.
