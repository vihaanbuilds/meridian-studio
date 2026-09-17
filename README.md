# Meridian Studio

A macOS-native, AI-assisted digital audio workstation (DAW) for
musicians who want to combine real performances (piano, saxophone,
etc.) with MIDI, virtual instruments, and AI-assisted production —
built with its own architecture and UX, not a clone of any existing
commercial DAW.

**Core principle:** the musician is the creative director. AI never
silently modifies a project — every AI suggestion is previewable,
reversible, explainable, editable, and non-destructive. (No AI code
ships yet — see the roadmap below.)

This repository is currently at **Phase 1**: a small, working app
shell (one MIDI track, MIDI recording/playback, a basic timeline and
piano roll, save/open). See
[`docs/superpowers/specs/2026-09-16-meridian-studio-design.md`](docs/superpowers/specs/2026-09-16-meridian-studio-design.md)
for the full architecture and phase roadmap.

## Requirements

- macOS with the Swift 6 toolchain (Xcode Command Line Tools are
  enough — a full Xcode install is **not** required for Phase 1).
- A class-compliant MIDI keyboard/controller (optional — the app is
  usable without one, just without live input).

## Build, run, test

```sh
swift build
swift run MeridianStudioApp
swift test
```

## Repository layout

```
Sources/
  MeridianStudioApp/   # SwiftUI app (UI layer)
  ProjectModel/        # Project/Track/Region/NoteEvent model, persistence
  MIDIEngine/          # CoreMIDI input, recording, playback scheduling
Tests/                 # Unit + integration tests for the above
docs/                  # Architecture, project format, MIDI, testing, evals
evals/                 # Structured pass/fail evaluation suites
```

## Status

Phase 1 in progress. See the design doc for the full 10-phase roadmap
(audio recording, mixer, automation, then the AI foundation and
AI-assisted arrangement/mixing layers).
