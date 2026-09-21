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

Undo/redo is model-level scaffolding only: `ProjectDocument` owns an
`UndoManager` that `addRegion`/`removeRegion`/`addTrack`/`removeTrack`
register with, and unit tests exercise undo and redo directly — but it
is not wired into the app's Edit menu or responder chain, so Cmd-Z does
nothing in the running app. Surfacing it in the UI remains deferred.

One hazard must be resolved before undo is ever wired up: the undo
closures registered by `addRegion`/`removeRegion` capture a track
*index*, and `removeTrack` (new in this branch) invalidates those indices
by shifting every later track down one. An undo of a region change that
straddles a track removal would therefore target the wrong track — or no
track at all, silently, via the bounds guard. It is unreachable today
only because no UI path can invoke undo; capturing the track `id` instead
of its index is the fix.

A second thing to settle before that day: `quantizeNotes`, like
`updateNote`, is a field edit with no undo registration — but unlike a
single-note edit it can discard an entire take's recorded timing in one
click, irreversibly. When undo is surfaced in the UI, that will need
reconsidering, most likely by registering a single compound undo action
covering the whole quantize pass.

Multi-track support (Phase 2): `addTrack`/`removeTrack` are
undo-registered structural operations, matching `addRegion`/
`removeRegion`; `setTrackMuted`/`setTrackSolo` are direct field
mutations with no undo registration, matching `setTempo` — undo is
reserved for structural add/remove throughout `ProjectDocument`, never
for field edits. `TrackAudibility.audibleTracks(in:)` implements the
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
