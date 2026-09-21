# Meridian Companion

Meridian Companion is the accessibility-first, rehab/therapy-facing
sibling to Meridian Studio, sharing only `ProjectModel`/`AudioEngine`
with it — see
`docs/superpowers/specs/2026-09-20-two-app-architecture-design.md` for
the architectural split and
`docs/superpowers/specs/2026-09-21-companion-record-play-trends-design.md`
for this app's first milestone.

## Session model

Unlike Meridian Studio, there is no manual Save As: the app auto-manages
its own session library under
`~/Library/Application Support/Meridian Companion/Sessions/`, one
`.mstudio` bundle per session, named `Session-<yyyyMMdd-HHmmss>.mstudio`.
Every bundle is written through unmodified `ProjectStore.save`/`.load` —
`SessionLibrary` (`Sources/MeridianCompanionApp/SessionLibrary.swift`)
owns the naming/scanning convention entirely within this app's own
target, not in `ProjectModel`, per the architecture spec's standing rule
that neither shared package grows an audience-specific concept.

## Modality auto-detection

At the start of each session, `CompanionState.hasMIDIDevice` checks
`MIDIGetNumberOfSources() > 0`. A MIDI device present records a
`.midi`-kind track via `CoreMIDIInput`/`MIDIRecorder`; otherwise a
`.audio`-kind track records via `AudioRecorder` — both exactly as
Meridian Studio's own `AppState` uses them. Detection is fresh at every
Start, not cached at launch, since a keyboard could be plugged in or
unplugged between sessions. Because CoreMIDI has no hot-plug support in
this codebase (see `docs/midi.md`), `startSession()`'s `.midi` branch
also closes and reopens `midiInput` right before recording, so a
keyboard connected after launch is actually picked up rather than just
detected — without this, `hasMIDIDevice` could report `true` while the
already-open MIDI port was still connected to nothing.

## Trends

`SessionLibrary.loadHistory(from:)` scans the session library and
computes two metrics only — session frequency and duration — chosen
specifically because they're computable identically for MIDI and audio
sessions. Note-level/timing-consistency metrics are deferred to a later
milestone; the underlying `NoteEvent.startBeat` data is already being
recorded and saved, so nothing here blocks adding that metric later.

## Known limitations

If no MIDI device is present and microphone access is denied, an audio
session still "succeeds" while capturing only silence — no error is
surfaced anywhere beyond the generic "didn't record anything" message
`stopSession()` shows for any empty take. Same class of gap as Meridian
Studio's own recording path (see `docs/audio.md`); not solved by this
milestone. A denied-microphone session is indistinguishable, from the
app's point of view, from any other take that captured nothing.
