# Testing

- `Tests/ProjectModelTests` — Codable round-trips, `Tempo` beat/second
  math, `ProjectStore` save/load and schema-version rejection,
  `ProjectDocument` undo/redo.
- `Tests/MIDIEngineTests` — `MIDIEventQueue` ordering/overflow,
  `MIDIMessageParser` byte parsing, `MIDIRecorder` note pairing,
  `PlaybackScheduler` beat-to-second math, and an integration test
  (`RecordAndPersistIntegrationTests`) that drives synthetic MIDI
  events through recording, saving, and reopening a project and
  asserts the result is identical.
- `CoreMIDIInput` and `PlaybackEngine` are hardware-touching adapters
  with no automated tests (they need a real CoreMIDI daemon/audio
  device); they're covered by build success plus the manual smoke
  tests in the Phase 1 implementation plan.
- Run everything: `swift test`. CI (`.github/workflows/ci.yml`) runs
  the same command on every push/PR.
