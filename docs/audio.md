# Audio Engine

## Recording
`AudioRecorder` taps `AVAudioEngine.inputNode` and writes each buffer to
an `AVAudioFile` directly inside the tap callback, computing a peak
level (`AudioLevelMeter.peak(of:)`) the same way. This is the standard,
widely-used pattern for straightforward single-track recording — it is,
in fact, what Apple's own basic recording sample code does — but it is
not the glitch-proof design a professional multitrack DAW eventually
needs: writing to disk from a real-time audio callback is not strictly
real-time-safe (file I/O can block), and under heavy system load this
could produce audible glitches or dropped buffers. A ring buffer
handed off to a separate writer thread — the same shape `MIDIEventQueue`
already uses for CoreMIDI input — is the fix, deferred until it proves
necessary in practice.

Recording onto an audio track requires the project to already have a
save location (`AppState.fileURL != nil`). Raw PCM audio cannot be held
in memory as a `Codable` value the way `NoteEvent`s are; it must live in
a file, and a brand-new project has no bundle to put one in yet.
Building temporary-file staging (recording to a scratch location, then
promoting/copying it into the bundle at first save, with cleanup on
discard) is real, additional complexity this milestone defers — the app
surfaces a clear alert rather than crashing or silently failing.

## Playback
`PlaybackEngine` schedules audio regions via `AVAudioPlayerNode.scheduleFile(at:)`
using sample-accurate `AVAudioTime` — a meaningfully different approach
from the existing MIDI note scheduling, which uses wall-clock
`Task.sleep` (see docs/midi.md). Both paths currently produce the same
"audible and roughly in sync" result; unifying them under one scheduling
strategy is a candidate future refinement, not a Phase 3 requirement.

## Level meters
`AudioLevelMeter.peak(of:)` is a simple peak meter — the largest
absolute sample value across every channel and frame in one buffer —
not RMS, not a calibrated dB scale, and with no peak-hold. It is pure
and hardware-free, so it is the one piece of audio metering with
automated test coverage; `AudioRecorder`/`PlaybackEngine`'s actual tap
installation is hardware-adjacent and untested, matching this project's
existing precedent for `CoreMIDIInput`. `LevelMeterView` renders it as a
plain proportional bar. A real meter (logarithmic scale, peak-hold,
color zones) is later polish.

## Importing existing audio
A later Phase 3 milestone (see
`docs/superpowers/specs/2026-09-21-audio-import-design.md`) added
`AppState.importAudio()`: File > Import Audio… copies a picked file
into the project bundle (never transcodes it) and always creates a new
audio track for it — never appends to an existing track. That's a
deliberate scope limit, not an oversight: `PlaybackEngine` only ever
plays a track's most recent audio region (see "Playback" above), so a
second region on one track would render in the timeline but never be
heard. Every audio track this way holds exactly one region, which keeps
that existing behavior correct. Playing multiple regions on one track
together is real, unscoped future work.

## Non-goals of this milestone
No waveform rendering (a real visual of the recorded shape, not just a
level meter), no trim/split/fade/normalize, no per-track gain/pan, and
no glitch-proof capture under load — all deferred to later Phase 3
milestones or Phase 4's mixer.
