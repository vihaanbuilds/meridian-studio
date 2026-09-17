# Eval: MIDI Recording

**Input:** A MIDI note-on for pitch 60 (middle C) at velocity 100,
followed one beat later by a matching note-off.

**Expected result:** `MIDIRecorder` produces exactly one `NoteEvent`
with `pitch: 60`, `velocity: 100`, `startBeat: 0`, `lengthBeats: 1`.

**Pass/fail criteria:** Exact match on pitch and velocity; timing
tolerance is whatever the injected clock reports (deterministic in
tests). No duplicate notes, no dropped notes.

**Automated by:** `Tests/MIDIEngineTests/MIDIRecorderTests.swift`.
