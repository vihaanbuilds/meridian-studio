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
`PlaybackEngine` schedules audio regions via `AVAudioPlayerNode.scheduleSegment(_:startingFrame:frameCount:at:)`
using sample-accurate `AVAudioTime` — a meaningfully different approach
from the existing MIDI note scheduling, which uses wall-clock
`Task.sleep` (see docs/midi.md). Both paths currently produce the same
"audible and roughly in sync" result; unifying them under one scheduling
strategy is a candidate future refinement, not a Phase 3 requirement.
`scheduleSegment` (rather than the whole-file `scheduleFile`) is what
makes trim and split possible: it schedules only the slice of the
underlying file a region's `sourceOffsetSeconds`/`lengthBeats` actually
covers, so a trimmed or split region plays back without touching the
file on disk. All regions share one `AVAudioPlayerNode`, so
`AppState.resolveAudioRegions` sorts them chronologically before
scheduling — see "Trim & split" below.

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
audio track for it — never appends to an existing track. Every region
on a track plays today (see "Trim & split" below), so this isn't a
playback-correctness workaround; it's just that there's no UI yet for
placing an imported file at a chosen beat on an existing track without
colliding with what's already there, so a new track — starting the
import at beat 0 with nothing to collide with — is the simple,
unambiguous choice. Importing onto an existing track at a chosen
position is real, unscoped future work.

## Trim & split
A later Phase 3 milestone (see
`docs/superpowers/specs/2026-10-02-audio-trim-split-design.md`) added
non-destructive trimming and splitting of audio regions directly in the
timeline: drag either edge handle to trim, or double-click inside a
region to split it into two. Neither operation reads, copies, or writes
the underlying audio file — both only change an `AudioRegion`'s
`startBeat`/`lengthBeats`/`sourceOffsetSeconds`, which is what makes
them non-destructive and instant. `sourceOffsetSeconds` is how far into
the file a region's playback starts; trimming the leading edge moves
`startBeat`/`sourceOffsetSeconds` together (and cannot push either past
the file's own start or the region's own start, see
`TimelineView.trimLeadingGesture`), trimming the trailing edge only
changes `lengthBeats`, and splitting a region replaces it with two new
regions that share its `fileName` and partition its
`sourceOffsetSeconds` range. `WaveformView` renders the matching slice
of the cached `WaveformBands` via `WaveformBands.slice`, so a trimmed or
split region's waveform always matches what will actually play.

A region's playback length follows `lengthBeats` *at the current
tempo* — `PlaybackEngine` converts beats to seconds with
`Tempo.seconds(forBeats:tempo:)` at play time, not at record/trim time —
so changing the project's tempo after recording or trimming a region
changes how much of the underlying file that region plays, including
for regions that predate this feature. This is pre-existing beats-based
behavior, not something trim/split introduced, but it's sharper now
that `sourceOffsetSeconds` makes "how much of the file" a user-visible,
directly-manipulated quantity.

Every region on a track plays back now, not just the most recent one —
splitting a region doubles a track's region count, so "only the most
recent region is heard" stopped being true the moment split shipped.
`AppState.resolveAudioRegions` resolves every audible track's every
audio region and sorts the results chronologically by `startBeat`
before handing them to `PlaybackEngine`, since all audio shares one
`AVAudioPlayerNode` and a split leaves the model's `audioRegions` array
in non-chronological order (the original is removed and both halves are
appended at the end).

## Waveform rendering
Later Phase 3 milestones added an actual visual of each `AudioRegion`'s
shape in the timeline, not just the live level meter above. First,
`WaveformPeaks` drew one combined time-domain peak per 512-sample bucket
(see `docs/superpowers/specs/2026-09-21-waveform-rendering-design.md`).
That was then replaced outright by `WaveformBands`
(`Sources/AudioEngine/WaveformBands.swift`), which computes three
FFT-derived frequency-band energies per bucket — low/bass, mid/vocals,
high/cymbals — rendered as three overlaid colored traces instead of one
(see `docs/superpowers/specs/2026-09-29-multiband-waveform-design.md`).
Both are offline-only (computed after a take is recorded or a file is
imported, with lazy backfill for older regions), cached next to the
audio file (`.bandpeaks`, superseding the earlier `.peaks` format), and
Meridian Studio-only — Companion has no per-region waveform view.

## Non-goals of this milestone
No fade/normalize, no per-track gain/pan, and no glitch-proof capture
under load — all deferred to later Phase 3 milestones or Phase 4's
mixer. (Waveform rendering and trim/split were both non-goals of *this*
milestone specifically but have since shipped — see "Waveform
rendering" and "Trim & split" above.)
