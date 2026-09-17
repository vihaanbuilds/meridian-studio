# Meridian Studio — Phase 0 Architecture & Phase 1 Milestone Design

Date: 2026-09-16
Status: Approved

## 1. Product Vision

Meridian Studio is a macOS-native, AI-assisted digital audio workstation
(DAW), inspired by the capabilities of modern DAWs but with its own
architecture, UX, and visual identity — no proprietary code, assets,
branding, or UI from any commercial DAW is copied.

The core workflow:

```
Musician performs
  → DAW records performance
  → AI analyzes musical content
  → AI suggests improvements
  → musician accepts/rejects/edits suggestions
  → DAW produces the final arrangement
  → musician mixes/masters/exports the track
```

Non-negotiable product rule: **AI must never silently modify the user's
project.** Every AI-generated change must be previewable, reversible,
explainable, editable, and non-destructive. This rule shapes the AI
architecture (Section 8) even though no AI code ships in Phase 1.

## 2. Development Principles (carried through every phase)

- Build incrementally; the app stays runnable after every milestone.
- Separate UI, project model, audio engine, MIDI engine, and AI systems
  into independently testable layers.
- Never block, allocate, log, or hit the network from a real-time audio
  callback.
- Destructive operations are undoable.
- A feature isn't "done" until its tests and evals pass — not merely
  when it compiles.
- When a requirement is ambiguous, pick the simplest professional
  implementation and document the assumption (see Section 10).

## 3. Scope of This Document

This spec covers two things:

1. **Phase 0** — the overall architecture, technology choices, data
   model, and phase plan for the whole project (light detail for
   phases beyond Phase 1 — those get their own design passes later).
2. **Phase 1** — a fully detailed design for the first working
   milestone: a small macOS app with one MIDI track, MIDI keyboard
   input/recording/playback, a basic timeline and piano roll, and
   save/open, per the source prompt's explicit instruction not to
   jump directly into building the whole DAW.

Phases 2–10 (audio recording/editing, mixer, automation, AI foundation,
AI music assistant, AI audio analysis, AI mix assistant,
professionalization) are listed in Section 9 as a roadmap only. Each
gets its own brainstorming pass and spec before implementation, per the
"decompose large projects into sub-projects" rule — this document does
not attempt to fully design them now.

## 4. Environment Constraint

This machine has Xcode **Command Line Tools only** (no full Xcode
install): `swift 6.3.2`, target `arm64-apple-macosx26.0`, no
`xcodebuild`. Consequences for Phase 1:

- The app is built as a **pure Swift Package Manager executable
  target** using SwiftUI's `App` protocol — no `.xcodeproj` is
  required to build, run, or test it. `swift build`, `swift run`, and
  `swift test` all work with Command Line Tools alone.
- GitHub Actions macOS runners do have Xcode, so CI can still run
  `xcodebuild`-based checks if/when they become necessary (e.g. once
  an `.xcodeproj` is added for packaging/signing in a later phase).
- Proper `.app` bundle packaging, code signing for distribution,
  entitlements review, and Instruments profiling are deferred until
  Xcode is installed locally — not required for Phase 1's acceptance
  criteria (a locally runnable, testable app).

This is documented as an explicit assumption: Phase 1 optimizes for
"runnable and testable today" over "distributable .app today."

## 5. Repository Structure

```
meridian-studio/
  README.md
  LICENSE                          # MIT
  .gitignore
  Package.swift                    # SPM workspace: app + libraries
  Sources/
    MeridianStudioApp/             # SwiftUI app entry point, views (Layer 1: UI)
    ProjectModel/                  # Project/Track/Region/NoteEvent, Codable, undo (Layer 2)
    MIDIEngine/                    # CoreMIDI I/O, recording, playback scheduling (Layer 4)
  Tests/
    ProjectModelTests/
    MIDIEngineTests/
  docs/
    architecture.md
    project-format.md
    midi.md
    testing.md
    evals.md
    superpowers/specs/2026-09-16-meridian-studio-design.md   # this file
  evals/
    eval_project_io/
    eval_midi/
    README.md
  .github/workflows/ci.yml         # swift build && swift test on a macos runner
```

No C++, no JUCE, no audio-recording engine, no AI layer exist yet.
Adding them prematurely would violate YAGNI — they arrive in the phases
that actually need them (Section 9).

## 6. Technology & Dependency Choices

| Concern | Choice | Why |
|---|---|---|
| Language | Swift 6 | Native stack decision; no C++ needed until real-time DSP work in a later phase. |
| UI | SwiftUI | Native, modern, works as a plain SPM executable target without Xcode. |
| MIDI input | CoreMIDI | Apple-native, no dependency. |
| MIDI playback | `AVAudioEngine` + `AVAudioUnitSampler` (built-in Apple sampler sound) | No sample library/synth needed yet; ships with the OS. |
| Tests | XCTest | SPM-native, zero extra dependency. |
| Third-party dependencies | **None** in Phase 1 | Every dependency must have a documented reason (project principle); none are needed yet. |

JUCE was explicitly considered and rejected for now (per your choice of
the native Apple stack) — its GPL/commercial licensing terms only
matter once there's a C++ real-time audio engine to license, which
Phase 1 doesn't have. Revisit if/when Phase 3 (audio engine) work shows
a concrete need JUCE would solve better than `AVAudioEngine`/Core
Audio directly.

## 7. Data Model & Project File Format

A versioned, directory-based document bundle, e.g. `MySong.mstudio/`:

```
MySong.mstudio/
  project.json     # schemaVersion, sampleRate, tempo, timeSignature, tracks[]
  midi/            # reserved for future per-region MIDI files
```

Phase 1 assumption (documented per the "simplest professional
implementation" principle): MIDI note events are small, so they are
embedded directly as arrays inside `project.json` rather than written
as separate files under `midi/`. The `midi/` directory is still created
so the layout is stable once regions grow large enough to warrant
separate files (a later phase, not a Phase 1 concern).

`project.json` shape (illustrative, not final field-by-field spec):

```json
{
  "schemaVersion": 1,
  "sampleRate": 44100,
  "tempo": 120.0,
  "timeSignature": { "numerator": 4, "denominator": 4 },
  "tracks": [
    {
      "id": "UUID",
      "name": "Piano",
      "kind": "midi",
      "muted": false,
      "solo": false,
      "regions": [
        {
          "id": "UUID",
          "startBeat": 0.0,
          "lengthBeats": 16.0,
          "notes": [
            { "pitch": 60, "velocity": 100, "startBeat": 0.0, "lengthBeats": 1.0 }
          ]
        }
      ]
    }
  ]
}
```

`schemaVersion` exists from day one even though there is only one
version, with a migration function stubbed in `ProjectModel` and a test
that opens a `schemaVersion: 1` fixture — so the versioning/migration
path is exercised before it's actually needed (per the "test opening
older project versions" requirement in the source prompt, applied at
the smallest meaningful scale for Phase 1).

## 8. MIDI Engine Design (Phase 1 scope)

Real-time safety is mandatory even at this small scale:

1. The CoreMIDI callback (invoked on a CoreMIDI-managed thread) does
   the minimum possible work: parse raw MIDI bytes into a `NoteEvent`
   struct and push it onto a lock-free single-producer/single-consumer
   queue. No allocation, no logging, no project-model access, no locks
   on this thread.
2. A main-actor `MIDIRecorder` drains the queue via a `DispatchSourceTimer`
   (or similar), timestamps events against the transport clock, and
   appends them into the in-memory `ProjectModel` under undo tracking.
3. Playback walks the active region's note events and schedules
   `noteOn`/`noteOff` calls on `AVAudioUnitSampler` ahead of the audio
   clock (look-ahead scheduling, not per-sample callback work — no
   custom real-time audio callback is written in Phase 1 since
   `AVAudioEngine` owns that thread internally).

This mirrors Layer 3/4 separation from the source prompt (audio engine
vs. MIDI engine) even though Phase 1 has no custom audio engine code —
`AVAudioEngine` stands in for it until Phase 3 needs lower-level
control.

## 9. Phase Roadmap (detailed design deferred to each phase's own spec)

| Phase | Scope | Status |
|---|---|---|
| 0 | Architecture & planning | This document |
| 1 | App shell: transport, one MIDI track, MIDI record/playback, timeline, piano roll, save/open, tests | **This milestone — detailed below** |
| 2 | Full MIDI DAW: multi-track, quantization strength options, richer piano roll editing | Not started |
| 3 | Audio DAW: audio input recording, waveform, editing (trim/split/fades/normalize) | Not started |
| 4 | Mixer: channel strips, EQ, compressor, reverb, delay, metering | Not started |
| 5 | Automation: volume/pan/plugin params, read/write/touch/latch | Not started |
| 6 | AI foundation: service abstraction, project context, structured actions, approval system | Not started |
| 7 | AI music assistant: chords/melody/bass/drums/arrangement suggestions | Not started |
| 8 | AI audio analysis: BPM/key/chord/pitch detection, transcription | Not started |
| 9 | AI mix assistant: spectrum/loudness/masking analysis and recommendations | Not started |
| 10 | Professionalization: performance, stability, accessibility, plugin support, crash recovery | Not started |

Each phase begins with its own brainstorming session and spec before
any implementation, per the project's own "decompose large projects"
rule — this table is a roadmap, not a commitment to specific designs
for phases 2–10.

## 10. Assumptions Log

- Bundle/package identifier: `com.meridianstudio.app` (placeholder,
  trivially changeable — no Apple Developer Program membership is
  needed for local `swift run` development).
- Deployment target: macOS 14.0+ (broad-enough compatibility; nothing
  in Phase 1 requires a newer SwiftUI feature).
- License: MIT, copyright held as "Meridian Studio Contributors"
  pending a real legal-entity decision later.
- GitHub repo: public, under the `vihaanbuilds` account (confirmed
  with the user as the correct account for this project on this
  machine).
- No sample content/soundfonts are bundled; the sampler uses whatever
  default sound `AVAudioUnitSampler` ships with, purely to make
  playback audible for Phase 1 acceptance testing.

## 11. Testing & Eval Architecture

- **Unit tests** (`Tests/ProjectModelTests`, `Tests/MIDIEngineTests`):
  tempo/beat-bar conversion, MIDI byte parsing, `project.json`
  encode/decode round-trip, schema-version migration stub.
- **Integration test**: synthetic `NoteEvent`s fed through
  `MIDIRecorder` → `ProjectModel` → save → reopen → assert identical
  note data (mirrors source-prompt EVAL 001 "MIDI Recording" and EVAL
  005 "Project Persistence", scoped to what Phase 1 actually has).
- **Evals** (`/evals/eval_project_io`, `/evals/eval_midi`): each has a
  README stating input, expected result, pass/fail criteria, and
  tolerance, matching the source prompt's eval format at Phase-1 scale
  (full tempo/audio/mixer/AI/performance/UI eval suites arrive with
  the phases that introduce those subsystems).
- **CI** (`.github/workflows/ci.yml`): runs `swift build` and
  `swift test` on a macOS GitHub Actions runner on every push/PR.

## 12. Phase 1 Acceptance Criteria

- App launches to a main window with a transport (play/pause/stop,
  tempo field) and one MIDI track.
- Connecting a MIDI keyboard and playing notes appears in real time in
  a basic piano-roll view.
- Recording captures notes with correct pitch/velocity/timing within a
  documented tolerance.
- Playback of a recorded region is audible and stays in sync with the
  transport.
- New/Save/Save As/Open round-trip a `.mstudio` project losslessly
  (verified by the integration test in Section 11).
- `swift test` passes locally and in CI.
- README documents how to build/run/test without Xcode installed.

A feature here is not "done" until implementation, tests, and the
relevant evals all pass, per Section 2 — matching compile success is
not sufficient.
