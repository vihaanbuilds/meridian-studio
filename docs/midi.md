# MIDI Engine

## Input
`CoreMIDIInput` opens a `MIDIClient`/`MIDIInputPort` (classic MIDI 1.0
API) and connects to every currently available source. Its read
callback runs on a CoreMIDI-managed thread and does the minimum
possible work: extract 3-byte channel messages from each packet and
push a `RawMIDIMessage` onto `MIDIEventQueue`. It does not parse
running status or SysEx — a documented Phase 1 limitation.

### Phase 1 input limitations
- **No hot-plug.** `CoreMIDIInput.start()` enumerates
  `MIDIGetNumberOfSources()` exactly once, at launch, and connects the
  input port to each source it finds then. A keyboard plugged in after
  the app has started is **not** picked up — there is no
  `MIDIClientCreate` notification handler and no re-scan. Workaround:
  connect the keyboard first, then launch the app. Hot-plug support
  (a notify block plus reconnection) is Phase 2 work.
- **Timing resolution is bounded by the drain timer, not the
  hardware.** `RawMIDIMessage.timestamp` captures `mach_absolute_time()`
  in the read callback, but nothing downstream uses it for note timing:
  `MIDIRecorder` stamps each note from `NoteRecorderClock`, which reads
  the wall clock at the moment `AppState` drains the queue. That drain
  runs on a repeating 0.01 s `Timer`, so every recorded note is stamped
  **0–10 ms late** (one-sided: quantized up to the next drain tick,
  never early) **plus run-loop scheduling jitter** — a `Timer` on a busy
  main run loop can fire well after its deadline, so under heavy UI work
  the real error exceeds 10 ms. That is the honest Phase 1 tolerance:
  fine for the "recorded notes land roughly where you played them" bar,
  not good enough for tight quantized work. Note that the error is
  mostly a constant offset, so *relative* timing between notes in one
  take is better than the absolute figure suggests. Using the captured
  hardware timestamp is the fix, and is deferred.

## Recording
`MIDIMessageParser.parse(_:)` turns a `RawMIDIMessage` into a
`ParsedMIDIEvent` (`.noteOn`, `.noteOff`, `.other`). `MIDIRecorder`
pairs `.noteOn`/`.noteOff` events per pitch into `NoteEvent`s using an
injectable clock (`NoteRecorderClock`), which is what makes it
testable without real time or hardware. Pending note-ons are kept as a
*stack per pitch*, so a pitch retriggered before its note-off does not
overwrite the earlier note; note-offs resolve LIFO. Keys still held when
recording stops are closed out by `MIDIRecorder.finalize(atBeat:)`,
which `AppState.stopRecording()` calls after a final drain and before it
clears the recording clock.

`AppState` drains `MIDIEventQueue` continuously for the app's whole
lifetime, not only during a take. Outside a take the drained events
still update `AppState.liveNotes` (pitch → press time), which
`PianoRollView` draws as a held-key highlight — that is what makes live
playing visible in real time. `MIDIRecorder.handle` is called only while
`isRecording` is true, so live monitoring never contaminates the
recorded take. `startRecording()` drains and discards the queue first so
pre-roll keystrokes do not land in the new take at bogus beats.

## Playback
`PlaybackScheduler.schedule(region:tempo:)` is pure beat-to-second math
(no I/O). `PlaybackEngine` uses it to schedule `AVAudioUnitSampler`
note on/off calls. This is wall-clock scheduling via `Task.sleep`, not
sample-accurate `AVAudioTime` scheduling — acceptable for Phase 1's
"audible and roughly in sync" bar; sample-accurate scheduling is a
candidate refinement once the mixer/automation phases need tighter
timing.

### Phase 2 limitation: one shared sampler, one MIDI channel
Every track plays through the *same* `AVAudioUnitSampler` instance on
MIDI channel 0 — `PlaybackEngine.play(regions:tempo:)` flattens all
audible regions into one stream of note on/off calls against that single
node. Two consequences: (a) simultaneous same-pitch notes on different
tracks interfere, because a note-off is addressed to a (pitch, channel)
pair and not to the track that sounded it, so one track's note-off cuts
short another track's still-sounding note at the same pitch; and (b)
every track sounds identical — there is no per-track instrument or preset
selection yet. The fix direction is one sampler (or at minimum one MIDI
channel) per track, wired into its own mixer input, which also gives
per-track volume and pan a place to live. Deferred.

`PlaybackEngine` keeps a handle on every scheduled note `Task` so
`stopAllNotes()` can cancel them and send note-off across all 128
pitches; Stop and a re-press of Play both go through it, so a stopped
transport really is silent and a second Play does not stack on top of
the previous run.
