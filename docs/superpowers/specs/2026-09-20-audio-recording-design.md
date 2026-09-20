# Audio Recording & Playback — Design

Date: 2026-09-20
Status: Approved
Phase: 3 (first milestone)

## 1. Scope

Phase 3 as a whole ("Audio DAW: audio input recording, waveform,
editing (trim/split/fades/normalize)" per the Phase 0 roadmap, plus
importing existing audio files per a standing user requirement) is
too large for one milestone — the same decomposition discipline Phase
2 used (multi-track → note editing → quantization) applies here.

This milestone is the foundation: **record real audio (microphone
input) onto a track, and play it back** — nothing more. It
deliberately does not include:

- Visible waveform rendering (a real-time **level meter** — a simple
  moving bar, not a rendered waveform — ships instead; see §5).
- Trim/split/fade/normalize editing.
- Importing existing audio files (explicitly required for a later
  Phase 3 milestone, not this one).
- Multiple audio tracks playing back simultaneously with independent
  gain/pan (this milestone plays audio regions at unity gain,
  consistent with how MIDI playback has no per-track volume yet
  either — that's Phase 4's mixer).

## 2. Target Rename: `MIDIEngine` → `AudioEngine`

`Sources/MIDIEngine` currently houses every real-time I/O concern:
`CoreMIDIInput`, `MIDIRecorder`, `PlaybackEngine`, `PlaybackScheduler`.
This milestone adds the project's first non-MIDI real-time I/O
(microphone capture) to the same target — a name that stops
describing what it contains the moment that lands. Renaming now, before
more audio code accumulates under the wrong name, is cheaper than
renaming later. This is a Task 1, mechanical, zero-functional-change
rename: `Sources/MIDIEngine` → `Sources/AudioEngine`, `Tests/MIDIEngineTests`
→ `Tests/AudioEngineTests`, `Package.swift`'s target/product names,
and every `import MIDIEngine` (4 source files, 5 test files,
`AppState.swift`). Currently-descriptive docs (`docs/architecture.md`,
`docs/evals.md`, `docs/testing.md`) are updated to match. Historical
spec/plan documents (e.g. `docs/superpowers/specs/2026-09-16-*`,
`docs/superpowers/plans/2026-09-16-*`) are records of what was decided
at the time and are **not** retroactively edited, matching this
project's existing practice of never rewriting historical documents
after the fact.

## 3. Data Model (`ProjectModel`)

### `TrackKind` gains `.audio`

```swift
public enum TrackKind: String, Codable, Sendable {
    case midi
    case audio
}
```

### New `AudioRegion` type, structurally parallel to `MIDIRegion`

```swift
public struct AudioRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    /// Filename only (not a path) — resolved against the project bundle's
    /// `audio/` directory by the app layer. Keeping ProjectModel free of
    /// absolute paths means a project bundle can be moved/renamed on disk
    /// without invalidating it, matching the existing `.mstudio` bundle's
    /// relative-file convention (`midi/` is the same idea, reserved since
    /// Phase 1).
    public var fileName: String

    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double, fileName: String) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.fileName = fileName
    }
}
```

`lengthBeats` is computed once at record-stop time (recorded duration
in seconds → beats via the existing `Tempo` conversion, at the
project's tempo when recording started) and stored, exactly like
`MIDIRegion.lengthBeats` — not re-derived from the file on every load.

### `Track` gains `audioRegions`, with backward-compatible decoding

```swift
public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var muted: Bool
    public var solo: Bool
    public var regions: [MIDIRegion]
    public var audioRegions: [AudioRegion]

    public init(
        id: UUID = UUID(), name: String, kind: TrackKind = .midi,
        muted: Bool = false, solo: Bool = false,
        regions: [MIDIRegion] = [], audioRegions: [AudioRegion] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.muted = muted
        self.solo = solo
        self.regions = regions
        self.audioRegions = audioRegions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, muted, solo, regions, audioRegions
    }

    // Custom decode so a project file saved before this field existed still
    // opens: `audioRegions` defaults to `[]` when absent, the same pattern
    // already used for `NoteEvent.id`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        muted = try container.decode(Bool.self, forKey: .muted)
        solo = try container.decode(Bool.self, forKey: .solo)
        regions = try container.decode([MIDIRegion].self, forKey: .regions)
        audioRegions = try container.decodeIfPresent([AudioRegion].self, forKey: .audioRegions) ?? []
    }
}
```

A track holds regions of only the kind matching its own `kind`
(a `.midi` track's `audioRegions` stays empty; a `.audio` track's
`regions` stays empty) — enforced by convention at the call sites this
milestone adds (`AppState`), not by the type system, matching this
project's established preference for simple structures over premature
polymorphism (`TrackKind` itself is exactly this kind of
convention-enforced tag).

### `ProjectDocument` gains audio-region operations, mirroring region operations exactly

```swift
public func addAudioRegion(_ region: AudioRegion, toTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    project.tracks[trackIndex].audioRegions.append(region)
    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.removeAudioRegion(id: region.id, fromTrackAt: trackIndex)
        }
    }
}

public func removeAudioRegion(id: UUID, fromTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == id }) else { return }
    let removed = project.tracks[trackIndex].audioRegions.remove(at: index)
    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.addAudioRegion(removed, toTrackAt: trackIndex)
        }
    }
}
```

Byte-for-byte the same shape as `addRegion`/`removeRegion` — structural
add/remove, undo-registered, using the same `MainActor.assumeIsolated`
bridge every other undo closure in this file already uses (required —
CI's toolchain rejects the alternative, discovered earlier this
project).

### `ProjectStore` creates the (already-reserved) `audio/` directory

`ProjectStore.save` already creates `midi/` alongside `project.json`;
it now also creates `audio/` the same way. `ProjectStore.load` does
not need to change — it only ever reads `project.json`, and physical
audio files are read directly by the playback/recording code, not
through `ProjectStore`.

## 4. Real-Time Audio Capture (`AudioEngine`, the renamed target)

### The "must save first" constraint

Raw PCM audio is too large to hold as an in-memory value the way
`NoteEvent`s are — it must be written to a file, and a file needs a
location. Before a project has ever been saved, there is no project
bundle to write into (`AppState.fileURL` is `nil`). Rather than build
temporary-file staging and promotion-on-save (real complexity: cleanup
on discard, moving files at Save As, keeping regions' `fileName`
consistent through a move), **this milestone requires the project to
already have a save location before an audio track can be armed for
recording** — the same "defer the adjacent complexity" call this
project has made repeatedly (e.g. Phase 1/2's documented, deliberately
unresolved New/Open-mid-recording hazards). `AppState` blocks/alerts
rather than silently failing.

### `AudioRecorder`

New file, `Sources/AudioEngine/AudioRecorder.swift`:

```swift
public final class AudioRecorder {
    private let engine: AVAudioEngine
    private var audioFile: AVAudioFile?
    private let currentLevel = OSAllocatedUnfairLock<Float>(initialState: 0)

    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    public func start(to url: URL) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        audioFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.audioFile?.write(from: buffer)
            self.currentLevel.withLock { $0 = Self.peakLevel(of: buffer) }
        }
    }

    public func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        let url = audioFile?.url
        audioFile = nil
        currentLevel.withLock { $0 = 0 }
        return url
    }

    public var level: Float {
        currentLevel.withLock { $0 }
    }

    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                peak = max(peak, abs(samples[frame]))
            }
        }
        return peak
    }
}
```

**Real-time safety note, documented in code and in docs/midi.md's
sibling doc for audio:** writing to disk and computing a peak directly
inside the tap callback is the same "simplest professional
implementation" tradeoff already made for MIDI timing (see
`docs/midi.md`) — not the glitch-proof ring-buffer-plus-writer-thread
design a professional multitrack DAW eventually needs under heavy
system load, but the standard, widely-used pattern for straightforward
single-track recording (it is, in fact, what Apple's own basic
recording sample code does). `currentLevel` uses the same
`OSAllocatedUnfairLock` pattern already established for
`MIDIEventQueue`, for the same genuine-`Sendable`-without-`@unchecked`
reason.

### `PlaybackEngine` plays audio regions too

`PlaybackEngine` (already renamed-target-resident) gains an
`AVAudioPlayerNode`, attached/connected in `init` alongside the
existing sampler, and its `play` signature grows to accept resolved
audio regions:

```swift
public func play(regions: [MIDIRegion], audioRegions: [(url: URL, startBeat: Double)], tempo: Double) {
    stopAllNotes()
    // ... existing per-region MIDI note scheduling, unchanged ...
    for audioRegion in audioRegions {
        guard let file = try? AVAudioFile(forReading: audioRegion.url) else { continue }
        let startSeconds = Tempo.seconds(forBeats: audioRegion.startBeat, tempo: tempo)
        let when = AVAudioTime(sampleTime: AVAudioFramePosition(startSeconds * file.processingFormat.sampleRate), atRate: file.processingFormat.sampleRate)
        audioPlayerNode.scheduleFile(file, at: when)
    }
    audioPlayerNode.play()
}
```

`(url: URL, startBeat: Double)` is deliberately a plain tuple, not
`AudioRegion` itself — `AudioEngine` stays decoupled from needing to
resolve filenames into bundle-relative paths; the app layer
(`AppState`) does that resolution and hands over ready-to-play URLs,
the same separation of concerns already used for MIDI (`AppState`
resolves `selectedTrackIndex` before `PlaybackEngine` ever sees a
concrete region).

`stopAllNotes()` gains a matching `audioPlayerNode.stop()` so Stop
silences audio playback the same way it already silences MIDI.

## 5. Level Meters (the "visual of input/output")

Not a waveform — a live numeric/bar readout, mirroring how Phase 1's
live MIDI-note highlighting shipped well before full piano-roll editing
existed.

- **Input meter**: while an audio track is armed and recording,
  `AppState` polls `AudioRecorder.level` on the same timer that already
  drains the MIDI queue (`Self.queuePollInterval`, 100Hz) and publishes
  it as `@Published var inputLevel: Float`.
- **Output meter**: `PlaybackEngine` installs a tap on the audio player
  node once, in `init` (permanently, mirroring how the node itself is
  attached once and reused across every `play()` call — not
  installed/removed per play/stop cycle), using the same peak-level
  technique as `AudioRecorder`. It reads naturally as 0 whenever
  nothing is scheduled, since the tap only receives silence with no
  material to peak. Exposed as `PlaybackEngine.level: Float`; `AppState`
  polls it into `@Published var outputLevel: Float` on the same timer.
- **UI**: a new small `LevelMeterView` (a horizontal bar,
  `width * CGFloat(level)`) — one instance shown near the transport for
  input, one for output. Deliberately minimal; a proper meter
  (logarithmic/dB scale, peak-hold, color zones) is a later polish
  pass, not this milestone's job.

## 6. `AppState` Wiring

- New `func armAudioTrack()` / extends `toggleRecording()`: when the
  selected track's `kind == .audio`, recording start/stop routes to
  `AudioRecorder` instead of `MIDIRecorder`. Guards `fileURL != nil`
  (see §4) before starting, surfacing an alert if not (mirroring
  `ProjectDocumentIO`'s existing `NSAlert(error:)` pattern for
  `ProjectStoreError`).
- `stopRecording` for an audio track: stops the recorder, gets the
  written file's URL, computes `lengthBeats` from the file's duration
  and the current tempo, constructs an `AudioRegion` with a filename
  derived from the region's own `id`, and adds it to the track's
  `audioRegions` (a new `ProjectDocument.addAudioRegion`, undo-registered,
  mirroring `addRegion`/`removeAudioRegion` exactly).
- `play()`: for each audible track with `kind == .audio`, resolve its
  `audioRegions.last`'s `fileName` against the project bundle's
  `audio/` directory (requires `fileURL`; an audio track with no saved
  project location cannot have recorded anything yet anyway, so this
  is never reached with a nil `fileURL` in practice) and pass the
  resolved `(url, startBeat)` list to the extended
  `playbackEngine.play(regions:audioRegions:tempo:)`.

## 7. Testing

- `ProjectModelTests`: `TrackKind.audio` round-trips through
  Codable; `AudioRegion` Codable round-trip; `Track` decodes a legacy
  JSON literal missing `audioRegions` into `[]` (mirrors
  `NoteEventTests`' missing-`id` test exactly); `ProjectDocument.
  addAudioRegion`/`removeAudioRegion` undo/redo (mirrors `addRegion`/
  `removeRegion` exactly).
- `AudioEngineTests` (renamed from `MIDIEngineTests`):
  `AudioRecorder.peakLevel(of:)`-equivalent pure logic tested directly
  against hand-built `AVAudioPCMBuffer`s (silence → 0, a known
  sample value → that exact peak, multi-channel → the max across
  channels) — this is the one piece of `AudioRecorder` that's pure
  enough to unit test without a real audio device; the tap/file-writing
  parts are hardware-adjacent and follow this project's existing
  precedent (no automated tests for `CoreMIDIInput`/`PlaybackEngine`'s
  hardware-facing pieces, verified by build + the manual smoke test).
- `AppState`/UI: no automated tests, matching established precedent.
- Manual smoke test (already pending from every prior milestone, this
  one adds to the checklist): arm an audio track, confirm the input
  meter moves while speaking/playing into the mic, record a few
  seconds, stop, confirm a region appears, hit Play, confirm audio
  plays back and the output meter moves, confirm Stop silences it.

## 8. Non-Goals / Explicit Deferrals

- Waveform rendering (a real visual of the recorded shape, not just a
  level meter).
- Trim/split/fade/normalize.
- Importing existing audio files (a later Phase 3 milestone — tracked
  separately as a standing requirement).
- Recording audio before the project has ever been saved.
- Per-track gain/pan for audio (Phase 4's mixer).
- Multiple simultaneous audio tracks with independent processing —
  this milestone plays every audible audio track's most recent region
  at unity gain, same "just enough to be real" bar Phase 1's MIDI
  playback set.
- Glitch-proof (ring-buffer) audio capture under system load — documented
  as a known limitation, matching the MIDI timing-tolerance precedent.
