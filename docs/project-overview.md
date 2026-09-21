# Project Overview

A quick-reference snapshot of what this repository is, what it's for,
and how it's laid out — for orientation, not as the authoritative spec
for any one piece. The authoritative documents are linked throughout;
this page summarizes and points, it doesn't replace them.

## Final Objective

Two native macOS apps sharing one foundation:

1. **Meridian Studio** — an AI-assisted digital audio workstation for
   musicians who want to combine real performances (piano, saxophone,
   vocals, etc.) with MIDI, virtual instruments, and AI-assisted
   production. Core workflow: musician performs → DAW records → AI
   analyzes and suggests improvements → musician accepts/rejects/edits
   → DAW produces the final arrangement → musician mixes/masters/exports.
   **Non-negotiable rule:** AI must never silently modify a project —
   every AI-generated change must be previewable, reversible,
   explainable, editable, and non-destructive. (No AI code has shipped
   yet — see Roadmap below.)
   Full vision: `docs/superpowers/specs/2026-09-16-meridian-studio-design.md`.

2. **Meridian Companion** — an accessibility-first, rehab/therapy-facing
   sibling app, for a patient to record short practice sessions
   (whatever input they have — a MIDI keyboard or just a microphone)
   and see simple progress trends over time, with a clinician reviewing
   async. Deliberately minimal: no editing surface, no precision
   controls, built for macOS Switch Control.
   Full vision: `docs/superpowers/specs/2026-09-20-two-app-architecture-design.md`.

The two apps share **only** their data model and real-time I/O layers
— never UI code, never a dependency on each other — so neither app's
complexity or constraints can leak into the other.

## Current Structure

```
meridian-studio/
  Package.swift                    # SwiftPM workspace: 2 libraries + 2 apps
  Sources/
    ProjectModel/                  # SHARED — data model, Codable, undo, persistence
      Project.swift                  Project (tempo, time signature, tracks)
      Track.swift                    Track, TrackKind (.midi / .audio)
      MIDIRegion.swift, NoteEvent.swift, AudioRegion.swift
      Quantizer.swift, Tempo.swift, TimeSignature.swift
      ProjectDocument.swift          UndoManager-backed observable wrapper
      ProjectStore.swift             versioned .mstudio bundle persistence
    AudioEngine/                    # SHARED — real-time MIDI + audio I/O
      CoreMIDIInput.swift, MIDIEventQueue.swift, RawMIDIMessage.swift
      MIDIMessageParser.swift, MIDIRecorder.swift
      PlaybackEngine.swift, PlaybackScheduler.swift
      AudioRecorder.swift, AudioLevelMeter.swift
    MeridianStudioApp/              # Musician-facing DAW — full editing UI
      AppState.swift, AppState+AudioRecording.swift
      ContentView.swift, TransportView.swift, TrackListView.swift
      TimelineView.swift, PianoRollView.swift, QuantizeControlView.swift
      ProjectDocumentIO.swift, RecordingClock.swift, LevelMeterView.swift
    MeridianCompanionApp/           # Therapy-facing companion — minimal UI
      CompanionState.swift, SessionLibrary.swift
      ContentView.swift, LevelMeterView.swift, RecordingClock.swift
      MeridianCompanionApp.swift
  Tests/
    ProjectModelTests/, AudioEngineTests/, MeridianCompanionAppTests/
  docs/                            # architecture.md, audio.md, midi.md,
                                    # companion.md, project-format.md,
                                    # testing.md, evals.md
  docs/superpowers/
    specs/                          # one design doc per phase/milestone
    plans/                          # one implementation plan per spec
  evals/                           # structured pass/fail eval suites
  .github/workflows/ci.yml         # swift build && swift test, macOS runner
```

Layering rule (enforced by `Package.swift`'s dependency graph, not just
convention): both apps depend on `ProjectModel`/`AudioEngine`; neither
app depends on the other; the shared packages depend on nothing app-
specific. Full detail: `docs/architecture.md`.

## Current Status

**Meridian Studio**
| Phase | Scope | Status |
|---|---|---|
| 1 | App shell: one MIDI track, record/playback, timeline, piano roll, save/open | Done |
| 2 | Multi-track (mute/solo), note-level editing, quantization | Done |
| 3, milestone 1 | Audio recording (mic) + playback, level meters | Done |
| 3, milestone 2 | Importing existing audio files + timeline audio-region rendering | In progress |
| 3, later | Waveform rendering, trim/split/fade/normalize | Not started |
| 4–10 | Mixer, automation, AI foundation, AI music/audio/mix assistants, professionalization | Not started |

**Meridian Companion**
| Milestone | Scope | Status |
|---|---|---|
| 1 | Auto-detected session recording, playback, basic frequency/duration trend chart | Done |
| Future | Clinician export/sharing, motor-precision metrics, session management | Not scoped yet |

Full phase roadmap: `docs/superpowers/specs/2026-09-16-meridian-studio-design.md` §9.
Every phase/milestone gets its own brainstorming → spec → plan cycle
before implementation — none of the "not started" rows above are
designed yet, only named as future scope.

## How Work Happens Here

Brainstorm (scope + design, with the user's approval) → write a spec
(`docs/superpowers/specs/`) → write an implementation plan
(`docs/superpowers/plans/`) → execute the plan task-by-task, each task
implemented and independently reviewed → one final whole-branch review
→ merge → push → verify CI green. See `docs/superpowers/specs/` and
`docs/superpowers/plans/` for the full history of every phase/milestone
built this way so far.
