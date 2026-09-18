# Architecture

Meridian Studio is a macOS-native DAW built in layers, mirroring the
separation described in the Phase 0 design spec
(`docs/superpowers/specs/2026-09-16-meridian-studio-design.md`):

- **UI** (`Sources/MeridianStudioApp`) — SwiftUI views: transport,
  track list, timeline, piano roll. Depends on `ProjectModel` and
  `MIDIEngine`, never the other way around.
- **Project Model** (`Sources/ProjectModel`) — `Project`, `Track`,
  `MIDIRegion`, `NoteEvent` value types (Codable, UI-independent),
  `ProjectStore` (versioned JSON persistence), and `ProjectDocument`
  (an `UndoManager`-backed observable wrapper). No SwiftUI import.
- **MIDI Engine** (`Sources/MIDIEngine`) — `CoreMIDIInput` (hardware
  adapter), `MIDIEventQueue` (thread-safe handoff off the CoreMIDI
  callback thread), `MIDIMessageParser`/`MIDIRecorder` (pure,
  unit-tested note-pairing logic), and `PlaybackEngine`/
  `PlaybackScheduler` (AVAudioEngine-based playback).

Undo/redo is model-level scaffolding only: `ProjectDocument` owns an
`UndoManager` that `addRegion`/`removeRegion`/`addTrack`/`removeTrack`
register with, and unit tests exercise undo and redo directly — but it
is not wired into the app's Edit menu or responder chain, so Cmd-Z does
nothing in the running app. Surfacing it in the UI remains deferred.

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

Real-time safety: the CoreMIDI read callback only parses bytes and
pushes onto `MIDIEventQueue` (allocation-free after construction,
guarded by `OSAllocatedUnfairLock`, drops events rather than blocking
when full). All project-model mutation happens on the main actor, off
that callback thread.

There is no audio-recording engine, mixer, or AI layer yet — see the
roadmap in the Phase 0 spec.
