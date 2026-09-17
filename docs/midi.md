# MIDI Engine

## Input
`CoreMIDIInput` opens a `MIDIClient`/`MIDIInputPort` (classic MIDI 1.0
API) and connects to every currently available source. Its read
callback runs on a CoreMIDI-managed thread and does the minimum
possible work: extract 3-byte channel messages from each packet and
push a `RawMIDIMessage` onto `MIDIEventQueue`. It does not parse
running status or SysEx — a documented Phase 1 limitation.

## Recording
`MIDIMessageParser.parse(_:)` turns a `RawMIDIMessage` into a
`ParsedMIDIEvent` (`.noteOn`, `.noteOff`, `.other`). `MIDIRecorder`
pairs `.noteOn`/`.noteOff` events per pitch into `NoteEvent`s using an
injectable clock (`NoteRecorderClock`), which is what makes it
testable without real time or hardware.

## Playback
`PlaybackScheduler.schedule(region:tempo:)` is pure beat-to-second math
(no I/O). `PlaybackEngine` uses it to schedule `AVAudioUnitSampler`
note on/off calls. This is wall-clock scheduling via `Task.sleep`, not
sample-accurate `AVAudioTime` scheduling — acceptable for Phase 1's
"audible and roughly in sync" bar; sample-accurate scheduling is a
candidate refinement once the mixer/automation phases need tighter
timing.
