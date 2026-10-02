# Audio Trim & Split — Design

Date: 2026-10-02
Status: Approved
Phase: 3 (final milestone — "editing (trim/split/fades/normalize)")

## 1. Scope

The last unstarted item in Phase 3 ("Audio DAW") is audio-region
editing. This milestone covers **trim** (drag a region's edges to play
less of its underlying file) and **split** (divide one region into
two at a clicked point). **Fade and normalize are a separate, later
milestone** — they need their own brainstorm, since both require a
real decision this project hasn't made yet: destructive edits (rewrite
the audio file) vs. non-destructive (a bigger change to the
single-shared-`AVAudioPlayerNode` playback architecture). Trim and
split avoid that question entirely: both are non-destructive, and both
build on one shared concept — a region can reference a sub-range of
its underlying file, which `AVAudioPlayerNode.scheduleSegment` already
supports natively.

Two pieces of required scope were discovered during design, not
optional additions:

- **Split cannot work today without a prerequisite fix.** `AppState
  .resolveAudioRegions` and the playback-duration calculation in
  `play()` only ever look at `track.audioRegions.last` — a deliberate
  simplification from the audio-import milestone ("every audio track
  holds exactly one region"). Split produces two regions per track, so
  this limit must be lifted. The shared `AVAudioPlayerNode` already
  schedules multiple simultaneous segments across different tracks
  today; this extends that to multiple regions within one track — not
  a playback-architecture change, just resolving/summing over every
  region instead of only the last.
- **Waveform rendering must slice, not just resize.** `WaveformBands`
  caches peaks for the *whole* file. A trimmed or split region plays
  only part of it; `WaveformView` must show only that sub-range, not
  the whole file's shape squeezed into a shorter frame.

Also in scope: fixing a pre-existing undo gap. `ProjectDocument
.updateNote` has never registered undo (note move/resize in
`PianoRollView` is silently non-undoable today). Trim introduces the
same kind of continuous-drag edit for audio regions, and leaving *that*
non-undoable while fixing it would be inconsistent — so both get fixed
together, via the same mechanism.

Deliberately out of scope:

- Fade in/out, normalize (next milestone).
- A playhead/scrubber (split triggers by clicking directly on the
  region instead — see §4).
- Any destructive edit — the underlying audio file is never rewritten
  by trim or split.
- Any change to Meridian Companion.
- Live audio preview during a drag (matches the existing note-drag
  precedent — nothing plays while a note is being dragged either).

## 2. Data Model

One new field on `AudioRegion`:

```swift
// Sources/ProjectModel/AudioRegion.swift
public struct AudioRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    public var fileName: String
    /// How far into the underlying file (in seconds) this region's
    /// playback starts. 0 for every region that predates this milestone
    /// and for any newly recorded/imported region — both play from the
    /// top of the file, matching today's behavior exactly.
    public var sourceOffsetSeconds: Double

    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double, fileName: String, sourceOffsetSeconds: Double = 0) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.fileName = fileName
        self.sourceOffsetSeconds = sourceOffsetSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, startBeat, lengthBeats, fileName, sourceOffsetSeconds
    }

    // A project file saved before this milestone has no `sourceOffsetSeconds`
    // key; it defaults to 0 (play from the top), matching every pre-existing
    // region's actual behavior exactly. Same pattern `Track.audioRegions`
    // already uses for its own migration — no `schemaVersion` bump.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startBeat = try container.decode(Double.self, forKey: .startBeat)
        lengthBeats = try container.decode(Double.self, forKey: .lengthBeats)
        fileName = try container.decode(String.self, forKey: .fileName)
        sourceOffsetSeconds = try container.decodeIfPresent(Double.self, forKey: .sourceOffsetSeconds) ?? 0
    }
}
```

`lengthBeats` keeps its existing meaning (how long the region plays in
the timeline). Combined with tempo and the file's sample rate, it now
also determines how many frames of the source file play, starting at
`sourceOffsetSeconds`.

## 3. Playback

`PlaybackEngine.play` switches from `scheduleFile` (plays a whole file)
to `scheduleSegment` (plays a sub-range):

```swift
// Sources/AudioEngine/PlaybackEngine.swift
public func play(regions: [MIDIRegion], audioRegions: [(url: URL, startBeat: Double, sourceOffsetSeconds: Double, lengthBeats: Double)], tempo: Double) {
    // ... MIDI scheduling unchanged ...
    for audioRegion in audioRegions {
        guard let file = try? AVAudioFile(forReading: audioRegion.url) else { continue }
        let sampleRate = file.processingFormat.sampleRate
        let startSeconds = Tempo.seconds(forBeats: audioRegion.startBeat, tempo: tempo)
        let when = AVAudioTime(
            sampleTime: AVAudioFramePosition(max(startSeconds, 0) * sampleRate),
            atRate: sampleRate
        )
        let startFrame = AVAudioFramePosition(audioRegion.sourceOffsetSeconds * sampleRate)
        let durationSeconds = Tempo.seconds(forBeats: audioRegion.lengthBeats, tempo: tempo)
        let requestedFrames = AVAudioFrameCount(max(durationSeconds, 0) * sampleRate)
        // Clamp to what's actually left in the file — a region's stored
        // length is normally consistent with its file, but this guards
        // against a corrupt/truncated file rather than trusting it blindly.
        let remainingFrames = AVAudioFrameCount(max(file.length - startFrame, 0))
        let frameCount = min(requestedFrames, remainingFrames)
        guard frameCount > 0 else { continue }
        audioPlayerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: when)
    }
    audioPlayerNode.play()
}
```

`AppState.resolveAudioRegions` and the playback-duration calculation in
`play()` change from "last region per track" to "every region per
track" — the prerequisite fix from §1:

```swift
// Sources/MeridianStudioApp/AppState.swift
private func resolveAudioRegions(in tracks: [Track]) -> [(url: URL, startBeat: Double, sourceOffsetSeconds: Double, lengthBeats: Double)] {
    guard let fileURL else { return [] }
    return tracks.flatMap { track in
        track.audioRegions.map { region in
            let url = fileURL.appendingPathComponent("audio").appendingPathComponent(region.fileName)
            return (url: url, startBeat: region.startBeat, sourceOffsetSeconds: region.sourceOffsetSeconds, lengthBeats: region.lengthBeats)
        }
    }
}
```

```swift
// In play(), replace:
//   audibleTracks.compactMap(\.audioRegions.last).map { ... }.max() ?? 0
// with:
let audioEndBeat = audibleTracks.flatMap(\.audioRegions).map { $0.startBeat + $0.lengthBeats }.max() ?? 0
```

No other playback call site resolves audio regions this way, so this
is the only place the "last region" assumption needs to be lifted.

## 4. Split

Triggered by a double-click (`onTapGesture(count: 2)`) directly on an
audio region's waveform — there's no playhead to split "at," so the
click position itself is the split point, converted to a beat via the
same `pixelsPerBeat` math `TimelineView` already uses for region
offset/width.

A click within `minimumRegionLengthBeats` (see §5) of either edge is
ignored — it would produce a degenerate near-zero-length half.

`ProjectDocument` gets one new method rather than composing split from
`removeAudioRegion`/`addAudioRegion`: chaining those would register
*three* separate undo steps (remove original, add first half, add
second half), so one undo press would only partially revert a split.
`splitAudioRegion` performs the same three-way mutation but registers
exactly one undo step, whose inverse re-merges the halves — mirroring
the existing mutual-re-registration idiom `addRegion`/`removeRegion`
already use for their own undo/redo symmetry:

```swift
// Sources/ProjectModel/ProjectDocument.swift
/// Splits the region with `id` into two at `splitBeat` (which must fall
/// strictly inside the region — the caller enforces the minimum-distance-
/// from-either-edge check). Both halves reference the same `fileName`; no
/// audio file is read, copied, or written. Registered as a single undo
/// step: undoing restores the original region, redoing re-splits it at
/// the same point.
public func splitAudioRegion(id: UUID, atBeat splitBeat: Double, tempo: Double, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == id }) else { return }
    let original = project.tracks[trackIndex].audioRegions[index]
    guard splitBeat > original.startBeat, splitBeat < original.startBeat + original.lengthBeats else { return }

    let firstLengthBeats = splitBeat - original.startBeat
    let elapsedSeconds = Tempo.seconds(forBeats: firstLengthBeats, tempo: tempo)
    let first = AudioRegion(
        startBeat: original.startBeat, lengthBeats: firstLengthBeats,
        fileName: original.fileName, sourceOffsetSeconds: original.sourceOffsetSeconds
    )
    let second = AudioRegion(
        startBeat: splitBeat, lengthBeats: original.lengthBeats - firstLengthBeats,
        fileName: original.fileName, sourceOffsetSeconds: original.sourceOffsetSeconds + elapsedSeconds
    )

    project.tracks[trackIndex].audioRegions.remove(at: index)
    project.tracks[trackIndex].audioRegions.append(first)
    project.tracks[trackIndex].audioRegions.append(second)

    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.mergeAudioRegions(first.id, second.id, into: original, splitBeat: splitBeat, tempo: tempo, inTrackAt: trackIndex)
        }
    }
}

/// The inverse of `splitAudioRegion` — removes both halves, restores
/// `original`, and registers undo for *this* operation as a call back
/// into `splitAudioRegion` at the same point, so redo re-splits.
private func mergeAudioRegions(_ firstID: UUID, _ secondID: UUID, into original: AudioRegion, splitBeat: Double, tempo: Double, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    project.tracks[trackIndex].audioRegions.removeAll { $0.id == firstID || $0.id == secondID }
    project.tracks[trackIndex].audioRegions.append(original)

    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.splitAudioRegion(id: original.id, atBeat: splitBeat, tempo: tempo, inTrackAt: trackIndex)
        }
    }
}
```

`AppState` gains a thin wrapper, `splitAudioRegion(id:atBeat:)`, that
supplies `document.project.tempo` and `selectedTrackIndex`.
`TimelineView`'s double-click handler converts its tap location to a
beat and calls it.

## 5. Trim

Two drag handles per audio region — leading and trailing — mirroring
`PianoRollView`'s existing note-resize handle (shape, `DragGesture
(minimumDistance: 2, coordinateSpace: .global)`, the `dragStart`-
captured-once-per-gesture pattern). The trailing handle is a direct
port: dragging it only changes `lengthBeats`. The leading handle is
new: dragging it right increases `sourceOffsetSeconds` *and*
`startBeat` together while decreasing `lengthBeats`, keeping the
region's right edge fixed in time — dragging it left reverses this,
back down to `sourceOffsetSeconds == 0` (undoing the trim, not
reaching into audio before the file's start).

```swift
// Sources/MeridianStudioApp/TimelineView.swift — shared constant, also
// used by split's "too close to either edge" check in §4.
private let minimumRegionLengthBeats: Double = 0.0625  // matches PianoRollView's minimumNoteLengthBeats

// Leading-handle drag (trailing handle mirrors PianoRollView.resizeGesture
// directly — length-only, no sourceOffsetSeconds change):
private func trimLeadingGesture(for region: AudioRegion, tempo: Double) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .global)
        .onChanged { value in
            let start = dragStartRegion ?? region
            if dragStartRegion == nil { dragStartRegion = region }
            let deltaBeats = Double(value.translation.width / pixelsPerBeat)
            // Clamp to two independent bounds: dragging right (positive delta)
            // can't shrink the region below minimumRegionLengthBeats; dragging
            // left (negative delta) can't push sourceOffsetSeconds below 0
            // (there's no audio before the file's own start).
            let maxDeltaBeats = start.lengthBeats - minimumRegionLengthBeats
            let minDeltaBeats = -Tempo.beats(forSeconds: start.sourceOffsetSeconds, tempo: tempo)
            let clampedDeltaBeats = min(max(deltaBeats, minDeltaBeats), maxDeltaBeats)
            var updated = start
            updated.startBeat = start.startBeat + clampedDeltaBeats
            updated.lengthBeats = start.lengthBeats - clampedDeltaBeats
            updated.sourceOffsetSeconds = start.sourceOffsetSeconds + Tempo.seconds(forBeats: clampedDeltaBeats, tempo: tempo)
            appState.updateAudioRegion(updated)
        }
        .onEnded { _ in
            if let dragStartRegion { appState.commitAudioRegionEdit(from: dragStartRegion) }
            dragStartRegion = nil
        }
}
```

### Undo (fixes the pre-existing gap from §1)

`ProjectDocument` gains the same two-tier shape introduced for notes:

```swift
// Sources/ProjectModel/ProjectDocument.swift
/// Live setter for the drag in progress — no undo registration. Called on
/// every `onChanged` frame; registering undo here would turn one drag
/// gesture into dozens of undo steps.
public func updateAudioRegion(_ region: AudioRegion, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == region.id }) else { return }
    project.tracks[trackIndex].audioRegions[index] = region
}

/// Called once, at drag-end, with the value captured when the drag
/// started. Registers one undo step for the whole gesture — restoring
/// `original` via the same mutual-re-registration idiom `addRegion`/
/// `removeRegion` already use, so redo works symmetrically.
public func commitAudioRegionEdit(from original: AudioRegion, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == original.id }) else { return }
    let current = project.tracks[trackIndex].audioRegions[index]
    guard current != original else { return }  // no-op drag (e.g. a click with no movement)
    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.updateAudioRegion(original, inTrackAt: trackIndex)
            doc.commitAudioRegionEdit(from: current, inTrackAt: trackIndex)
        }
    }
}
```

And — fixing the pre-existing gap — `NoteEvent`/`PianoRollView` get the
exact same two-tier split. `updateNote` stays the plain per-frame
setter it already is (no behavior change); a new method registers undo:

```swift
// Sources/ProjectModel/ProjectDocument.swift
public func commitNoteEdit(from original: NoteEvent, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
    guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == original.id }) else { return }
    let current = project.tracks[trackIndex].regions[regionIndex].notes[noteIndex]
    guard current != original else { return }
    undoManager.registerUndo(withTarget: self) { doc in
        MainActor.assumeIsolated {
            doc.updateNote(original, inTrackAt: trackIndex)
            doc.commitNoteEdit(from: current, inTrackAt: trackIndex)
        }
    }
}
```

Called once in `PianoRollView`'s `moveGesture`/`resizeGesture`'s
`onEnded`, using the same `dragStartNote` value those gestures already
capture — no new view state needed, just one new call (`appState
.commitNoteEdit(from: dragStartNote)`, a thin `AppState` wrapper
mirroring `moveOrResizeSelectedNote`) at a point that already exists.

## 6. Waveform Slicing

`WaveformView` must show only the sub-range of the file a (possibly
trimmed or split) region actually plays — not the whole file's shape.
`WaveformBands` gains a slicing method:

```swift
// Sources/AudioEngine/WaveformBands.swift
/// Returns the sub-range of buckets covering `fromSeconds..<toSeconds` of
/// the original file this `WaveformBands` was analyzed from. Used to show
/// only a trimmed/split region's actual played range, not the whole
/// file's waveform. Bucket boundaries, not sample-accurate — a visual
/// waveform doesn't need to be.
public func slice(fromSeconds: Double, toSeconds: Double, sampleRate: Double) -> WaveformBands {
    let bucketSeconds = Double(Self.samplesPerBucket) / sampleRate
    let startBucket = max(0, Int((fromSeconds / bucketSeconds).rounded(.down)))
    let endBucket = min(low.count, Int((toSeconds / bucketSeconds).rounded(.up)))
    guard startBucket < endBucket else { return WaveformBands(low: [], mid: [], high: []) }
    return WaveformBands(low: Array(low[startBucket..<endBucket]), mid: Array(mid[startBucket..<endBucket]), high: Array(high[startBucket..<endBucket]))
}
```

Calling it needs the file's sample rate, which `AppState+Waveforms
.swift`'s loader doesn't currently retain (the `.bandpeaks` cache
stores only magnitudes, no header — see the multiband-waveform spec's
§2 rationale for why that stays true here). Rather than change that
file format, `AppState` memoizes sample rate alongside bands, in a new
parallel cache populated at the same point `bandCache` already is —
one extra cheap `AVAudioFile` header read (not a full re-analysis),
whether that call hits the `.bandpeaks` cache or falls through to a
fresh `WaveformBands.analyze`:

```swift
// Sources/MeridianStudioApp/AppState.swift — alongside bandCache/bandLoadsInFlight
@Published var sampleRateCache: [String: Double] = [:]
```

```swift
// Sources/MeridianStudioApp/AppState+Waveforms.swift — waveformBands(for:)'s
// Task.detached block gains one line:
Task.detached(priority: .utility) {
    let bands = (try? WaveformBands.read(from: bandsFileURL)).flatMap { $0.low.isEmpty ? nil : $0 }
        ?? (try? WaveformBands.analyze(fileURL: audioFileURL))
    guard let bands else { return }
    try? bands.write(to: bandsFileURL)
    let sampleRate = (try? AVAudioFile(forReading: audioFileURL))?.processingFormat.sampleRate
    await MainActor.run {
        self.bandCache[region.fileName] = bands
        if let sampleRate { self.sampleRateCache[region.fileName] = sampleRate }
    }
}
```

`TimelineView`'s audio-region overlay becomes (replacing the direct
`WaveformView(bands: bands)` call):

```swift
if let bands = appState.waveformBands(for: region), let sampleRate = appState.sampleRateCache[region.fileName] {
    let durationSeconds = Tempo.seconds(forBeats: region.lengthBeats, tempo: appState.document.project.tempo)
    WaveformView(bands: bands.slice(fromSeconds: region.sourceOffsetSeconds, toSeconds: region.sourceOffsetSeconds + durationSeconds, sampleRate: sampleRate))
}
```

A region with `sourceOffsetSeconds == 0` and `lengthBeats` matching the
whole file (every pre-existing region, and every freshly recorded/
imported one) slices to the full bucket range — visually identical to
today, no behavior change for the common case.

## 7. Testing

- `WaveformBandsTests`: unit tests for `slice` — a sub-range in the
  middle, a range clamped at the file's start/end, and an empty/
  degenerate range (`fromSeconds >= toSeconds`) — pure logic, no
  hardware, matches this file's existing test precedent.
- `ProjectModelTests` (likely a new `AudioRegionEditingTests.swift` or
  additions to `ProjectDocumentTests`): `splitAudioRegion` produces two
  correctly-ranged halves and undoes/redoes as one step;
  `commitAudioRegionEdit`/`commitNoteEdit` register exactly one undo
  step per call and are no-ops when the value didn't actually change.
- No automated tests for the `TimelineView` drag gestures themselves —
  matches this project's established precedent that no SwiftUI view
  code has automated coverage anywhere in this codebase.
- Manual smoke test: trim a region from both edges and confirm
  playback only covers the trimmed range; split a region, confirm both
  halves play correctly and the waveform for each shows only its own
  slice; undo/redo a trim (one press each way) and a split (one press
  each way); drag a MIDI note and confirm it's now undoable too; open
  a project saved before this milestone and confirm its audio regions
  still play/render exactly as before (sourceOffsetSeconds defaults to
  0).

## 8. Non-Goals

- Fade in/out, normalize — next milestone, destructive-vs-non-
  destructive still undecided.
- A playhead/scrubber.
- Destructive edits of any kind — the audio file on disk is never
  rewritten.
- Any change to Meridian Companion.
- Live audio preview during a trim/split drag.
- Trimming or splitting MIDI regions (this milestone is audio-only;
  the undo fix for notes is the one exception, justified in §1 as
  fixing a gap this milestone would otherwise widen).
