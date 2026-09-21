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

This repository is currently through **Phase 2**: the Phase 1 app shell
(MIDI recording/playback, a basic timeline and piano roll, save/open)
plus full MIDI editing — multiple tracks with mute/solo, note-level
select/move/resize/delete in the piano roll, and quantization with
adjustable grid and strength. See
[`docs/superpowers/specs/2026-09-16-meridian-studio-design.md`](docs/superpowers/specs/2026-09-16-meridian-studio-design.md)
for the full architecture and phase roadmap.

## Requirements

- macOS with the Swift 6 toolchain.
- A class-compliant MIDI keyboard/controller (optional — the app is
  usable without one, just without live input).

## Build, run, test

```sh
swift build                   # Xcode Command Line Tools are enough
swift run MeridianStudioApp   # Xcode Command Line Tools are enough
swift test                    # requires a full Xcode install
```

**Toolchain caveat:** `swift build` and `swift run` work with Xcode
Command Line Tools alone, but `swift test` does **not** — SwiftPM's test
target links `XCTest.framework`, which ships only with a full Xcode
install, so with CLT alone the test files will not even compile. If you
only have Command Line Tools, install Xcode to run the suite locally, or
rely on CI (`.github/workflows/ci.yml`), which runs on a full-Xcode
runner image. Most of this branch was in fact developed CLT-only, with
test files verified by review rather than execution.

## Repository layout

```
Sources/
  MeridianStudioApp/     # SwiftUI app (UI layer)
  MeridianCompanionApp/  # SwiftUI companion app (see docs/companion.md)
  ProjectModel/          # Project/Track/Region/NoteEvent model, persistence
  AudioEngine/           # CoreMIDI input, recording, playback scheduling
Tests/                 # Unit + integration tests for the above
docs/                  # Architecture, project format, MIDI, testing, evals
evals/                 # Structured pass/fail evaluation suites
```

## Status

Phase 1 is code-complete: the app shell, MIDI recording/playback,
timeline, piano roll, and save/open are all implemented and covered by
unit and integration tests. The one remaining item is the manual smoke
test with real MIDI hardware described in the Phase 1 implementation
plan (`docs/superpowers/plans/2026-09-16-phase1-app-shell.md`), which
needs a physical keyboard and cannot be automated.

Phase 2 ("Full MIDI editing") is also code-complete: multi-track with
mute/solo, note select/move/resize/delete in the piano roll, and
quantization (adjustable grid and strength), all covered by unit tests
at the model layer. As in Phase 1, the SwiftUI and gesture layers have
no automated coverage — the per-milestone manual smoke tests in
`docs/superpowers/plans/` remain the outstanding item.

See the design doc for the full 10-phase roadmap (audio recording,
mixer, automation, then the AI foundation and AI-assisted
arrangement/mixing layers).
