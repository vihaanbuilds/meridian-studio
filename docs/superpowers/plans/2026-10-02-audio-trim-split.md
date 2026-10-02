# Audio Trim & Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user trim an audio region's edges and split one audio region into two, non-destructively, with full undo/redo — and fix a pre-existing undo gap for MIDI note editing along the way.

**Architecture:** A new `sourceOffsetSeconds` field on `AudioRegion` lets a region reference a sub-range of its underlying file. `PlaybackEngine` switches from playing a whole file (`scheduleFile`) to playing that sub-range (`scheduleSegment`). `AppState`/`ProjectDocument` gain a two-tier edit pattern (a plain per-frame setter for live drag feedback, a separate commit method called once at drag-end that registers exactly one undo step) — applied to both the new audio-region editing and, fixing a pre-existing gap, to MIDI note editing. `WaveformBands` gains a `slice` method so a trimmed/split region's waveform shows only its actual played range.

**Tech Stack:** Swift 6, SwiftUI (`DragGesture`, `SpatialTapGesture`), AVFoundation (`AVAudioPlayerNode.scheduleSegment`) — all either already used elsewhere in this codebase or (for `SpatialTapGesture`) available on this project's macOS 14+ deployment target.

**Spec:** `docs/superpowers/specs/2026-10-02-audio-trim-split-design.md`

## Global Constraints

- No `schemaVersion` bump. `AudioRegion.sourceOffsetSeconds` defaults to 0 via `decodeIfPresent(...) ?? 0`, mirroring `Track.audioRegions`' existing migration pattern — a project saved before this milestone loads and plays/renders identically to before.
- Non-destructive only — the audio file on disk is never rewritten by trim or split.
- Every continuous-drag edit (trim, and — fixing the pre-existing gap — MIDI note move/resize) registers exactly **one** undo step for the whole gesture, via a plain `update...` setter (no undo, called every `onChanged` frame) plus a separate `commit...Edit` method (registers undo, called once at `onEnded`) — never one undo step per frame.
- Split is one `ProjectDocument.splitAudioRegion` method, not three chained `removeAudioRegion`/`addAudioRegion` calls — chaining would register three separate undo steps, so one undo press would only partially revert a split.
- `PlaybackEngine.play` uses `scheduleSegment`, not `scheduleFile`. `AppState.resolveAudioRegions` and the playback-duration calculation in `play()` consider **every** audio region on a track, not just `track.audioRegions.last` (a prerequisite fix — split produces two regions per track, and the old "last region only" assumption predates this milestone).
- `WaveformBands.slice` is pure bucket-range arithmetic — no file I/O, and the `.bandpeaks` cache file format itself is unchanged.
- No automated tests for SwiftUI view code (`TimelineView.swift`, `PianoRollView.swift`) or hardware-adjacent `AudioEngine` code (`PlaybackEngine.swift`) — matches this project's established precedent (no `PlaybackEngineTests.swift` exists today).
- Out of scope, not touched by any task: fade/normalize, a playhead/scrubber, destructive edits, trimming/splitting MIDI regions, any change to Meridian Companion.

## Review Focus

- **Splitting at or beyond either edge of a region must be a silent no-op**, not a crash or a degenerate zero-length region — a double-click can land anywhere, including right at a region's boundary. → Task 3's own test.
- **Committing a drag that produced no actual change (e.g. a click with negligible movement) must register zero undo steps**, for both audio-region and note edits — an accidental no-op undo entry would make "undo" silently do nothing the next time it's pressed. → Task 4's own tests.
- **Sequential edits of different kinds (trim, then split) must each undo independently, in reverse order** — not merge into one undo step. This is the one thing no single task's isolated unit test can catch; it also doubles as an empirical check of `UndoManager`'s grouping behavior in a synchronous test run, which this plan has not independently verified. → Task 4's own test; if it fails, the likely cause is `UndoManager.groupsByEvent` merging separate top-level `registerUndo` calls more aggressively than expected in this environment, fixable with explicit `beginUndoGrouping()`/`endUndoGrouping()` boundaries around each commit.
- **An untrimmed region (`sourceOffsetSeconds == 0`, `lengthBeats` matching the file's full natural duration — true for every pre-existing region) must still play its entire length** after the `scheduleFile` → `scheduleSegment` switch — floating-point rounding in the beats↔seconds↔frames round trip must not truncate it early. Not automatable (no `PlaybackEngineTests.swift` precedent) — Task 2 and Task 6's manual smoke tests both call this out explicitly so it isn't skipped.
- **Dragging a trailing trim handle must not be able to request more of the file than actually exists** past `sourceOffsetSeconds` — without this clamp, the stored region would claim a length longer than its audio, and playback's own defensive clamp (in `PlaybackEngine`, meant only to guard against a corrupt file) would silently truncate it, leaving a region that visually extends further than it plays. → Task 6's trailing-handle clamp, using the file-duration cache Task 5 adds.

---

### Task 1: `AudioRegion.sourceOffsetSeconds`

**Files:**
- Modify: `Sources/ProjectModel/AudioRegion.swift` (full rewrite)
- Test: `Tests/ProjectModelTests/AudioRegionTests.swift`

**Interfaces:**
- Produces: `AudioRegion.sourceOffsetSeconds: Double` (stored property), `AudioRegion.init(id:startBeat:lengthBeats:fileName:sourceOffsetSeconds:)` (new param defaults to `0`, so every existing call site in `AppState+AudioRecording.swift`/`AppState+AudioImport.swift` keeps compiling unchanged). Used by every later task.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ProjectModelTests/AudioRegionTests.swift` (after the existing `testEncodeDecodeRoundTrips`, which stays as-is):

```swift
    func testSourceOffsetSecondsDefaultsToZero() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        XCTAssertEqual(region.sourceOffsetSeconds, 0)
    }

    func testEncodeDecodeRoundTripsWithNonZeroSourceOffset() throws {
        let original = AudioRegion(startBeat: 2, lengthBeats: 4, fileName: "abc.wav", sourceOffsetSeconds: 1.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioRegion.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.sourceOffsetSeconds, 1.5)
    }

    func testDecodesLegacyJSONMissingSourceOffsetSecondsAsZero() throws {
        let json = """
        {"id": "11111111-1111-1111-1111-111111111111", "startBeat": 0, "lengthBeats": 4, "fileName": "take1.wav"}
        """
        let region = try JSONDecoder().decode(AudioRegion.self, from: Data(json.utf8))
        XCTAssertEqual(region.sourceOffsetSeconds, 0)
        XCTAssertEqual(region.fileName, "take1.wav")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioRegionTests`
Expected: FAIL to build — "value of type 'AudioRegion' has no member 'sourceOffsetSeconds'".

- [ ] **Step 3: Implement**

Replace the full contents of `Sources/ProjectModel/AudioRegion.swift`:

```swift
import Foundation

public struct AudioRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    /// Filename only, never an absolute path — resolved against the project
    /// bundle's `audio/` directory by the app layer, so a bundle can be
    /// moved/renamed on disk without invalidating it.
    public var fileName: String
    /// How far into the underlying file (in seconds) this region's playback
    /// starts. 0 for every region that predates this field and for any
    /// newly recorded/imported region — both play from the top of the
    /// file, matching the behavior this field didn't change.
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

    // Custom decode so a project file saved before this field existed still
    // opens: it defaults to 0 (play from the top) when absent, the same
    // pattern `Track.audioRegions` already uses for its own migration.
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioRegionTests`
Expected: PASS (8 tests: the 5 pre-existing plus the 3 new ones).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/AudioRegion.swift Tests/ProjectModelTests/AudioRegionTests.swift
git commit -m "Add AudioRegion.sourceOffsetSeconds for non-destructive trim/split"
```

---

### Task 2: Playback — `scheduleSegment` and every-region resolution

**Files:**
- Modify: `Sources/AudioEngine/PlaybackEngine.swift:68-103` (the `play` function)
- Modify: `Sources/MeridianStudioApp/AppState.swift:209-250` (`play()`, `resolveAudioRegions`)

**Interfaces:**
- Consumes: `AudioRegion.sourceOffsetSeconds` (Task 1).
- Produces: `PlaybackEngine.play(regions:audioRegions:tempo:)`'s new `audioRegions` tuple shape — `[(url: URL, startBeat: Double, sourceOffsetSeconds: Double, lengthBeats: Double)]` — consumed only by `AppState.play()` in this same task. No other task calls `PlaybackEngine.play` or `resolveAudioRegions`.

No automated tests for this task — matches this project's established precedent for `PlaybackEngine` (hardware-adjacent `AVAudioEngine` code; no `PlaybackEngineTests.swift` exists). Verified by build and the manual smoke test in Step 5.

- [ ] **Step 1: Switch `PlaybackEngine.play` to `scheduleSegment`**

In `Sources/AudioEngine/PlaybackEngine.swift`, find:

```swift
    public func play(regions: [MIDIRegion], audioRegions: [(url: URL, startBeat: Double)], tempo: Double) {
```

Replace with:

```swift
    public func play(regions: [MIDIRegion], audioRegions: [(url: URL, startBeat: Double, sourceOffsetSeconds: Double, lengthBeats: Double)], tempo: Double) {
```

Then find:

```swift
        for audioRegion in audioRegions {
            guard let file = try? AVAudioFile(forReading: audioRegion.url) else { continue }
            let startSeconds = Tempo.seconds(forBeats: audioRegion.startBeat, tempo: tempo)
            let when = AVAudioTime(
                sampleTime: AVAudioFramePosition(max(startSeconds, 0) * file.processingFormat.sampleRate),
                atRate: file.processingFormat.sampleRate
            )
            audioPlayerNode.scheduleFile(file, at: when)
        }
```

Replace with:

```swift
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
            // Clamp to what's actually left in the file. For an untrimmed region
            // this should already match `requestedFrames` exactly (modulo
            // floating-point rounding in the beats<->seconds<->frames round trip);
            // this guard exists for a corrupt/truncated file, not to silently
            // paper over a real trim-bounds bug — Task 6's trim-handle clamp is
            // what actually keeps `requestedFrames` in range during normal use.
            let remainingFrames = AVAudioFrameCount(max(file.length - startFrame, 0))
            let frameCount = min(requestedFrames, remainingFrames)
            guard frameCount > 0 else { continue }
            audioPlayerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: when)
        }
```

- [ ] **Step 2: Fix `resolveAudioRegions` to resolve every region, not just the last**

In `Sources/MeridianStudioApp/AppState.swift`, find:

```swift
    /// Resolves each audible track's most recent audio region's filename against
    /// the project bundle's `audio/` directory. Requires `fileURL` — an audio
    /// track can only ever have a recorded region if the project was already
    /// saved (see `AppState+AudioRecording.swift`), so this never silently drops
    /// audio due to a nil `fileURL` in practice.
    private func resolveAudioRegions(in tracks: [Track]) -> [(url: URL, startBeat: Double)] {
        guard let fileURL else { return [] }
        return tracks.compactMap { track in
            guard let region = track.audioRegions.last else { return nil }
            let url = fileURL.appendingPathComponent("audio").appendingPathComponent(region.fileName)
            return (url: url, startBeat: region.startBeat)
        }
    }
```

Replace with:

```swift
    /// Resolves every audible track's audio regions' filenames against the
    /// project bundle's `audio/` directory — every region on a track, not
    /// just the most recent (a track can hold more than one after a split).
    /// Requires `fileURL` — an audio track can only ever have a recorded
    /// region if the project was already saved (see
    /// `AppState+AudioRecording.swift`), so this never silently drops audio
    /// due to a nil `fileURL` in practice.
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

- [ ] **Step 3: Fix the playback-duration calculation to consider every region**

In `Sources/MeridianStudioApp/AppState.swift`, find:

```swift
        let audioEndBeat = audibleTracks.compactMap(\.audioRegions.last).map { $0.startBeat + $0.lengthBeats }.max() ?? 0
```

Replace with:

```swift
        let audioEndBeat = audibleTracks.flatMap(\.audioRegions).map { $0.startBeat + $0.lengthBeats }.max() ?? 0
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 5: Manual smoke test**

- Record or import an audio take, play it, and confirm it plays in full from start to end — not truncated early (this is the Review Focus item: an untrimmed region's `scheduleSegment` call must cover the whole file).
- Play a project with two audio tracks together and confirm both still play simultaneously (regression check: the shared `AVAudioPlayerNode` still handles multiple regions across tracks).

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests still pass (this task adds none).

- [ ] **Step 7: Commit**

```bash
git add Sources/AudioEngine/PlaybackEngine.swift Sources/MeridianStudioApp/AppState.swift
git commit -m "Switch audio playback to scheduleSegment; resolve every region per track, not just the last"
```

---

### Task 3: Split — `ProjectDocument.splitAudioRegion`

**Files:**
- Modify: `Sources/ProjectModel/ProjectDocument.swift:48-57` (insert after `removeAudioRegion`)
- Modify: `Sources/MeridianStudioApp/AppState.swift` (add a thin wrapper)
- Test: `Tests/ProjectModelTests/ProjectDocumentTests.swift`

**Interfaces:**
- Consumes: `AudioRegion.sourceOffsetSeconds` (Task 1), `Tempo.seconds(forBeats:tempo:)` (pre-existing).
- Produces: `ProjectDocument.splitAudioRegion(id:atBeat:tempo:inTrackAt:)`, `AppState.splitAudioRegion(id:atBeat:inTrackAt:)` — consumed by Task 6's `TimelineView`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ProjectModelTests/ProjectDocumentTests.swift`, after `testUndoReInsertsRemovedAudioRegion` (just before the file's closing `}`):

```swift
    func testSplitAudioRegionProducesTwoCorrectlyRangedHalves() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tempo: 120, tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        doc.splitAudioRegion(id: region.id, atBeat: 1, tempo: 120, inTrackAt: 0)

        let regions = doc.project.tracks[0].audioRegions
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].startBeat, 0)
        XCTAssertEqual(regions[0].lengthBeats, 1)
        XCTAssertEqual(regions[0].sourceOffsetSeconds, 0)
        XCTAssertEqual(regions[0].fileName, "take1.wav")
        XCTAssertEqual(regions[1].startBeat, 1)
        XCTAssertEqual(regions[1].lengthBeats, 3)
        XCTAssertEqual(regions[1].sourceOffsetSeconds, 0.5, accuracy: 0.0001)  // 1 beat at 120bpm = 0.5s
        XCTAssertEqual(regions[1].fileName, "take1.wav")
    }

    func testSplitAudioRegionAtOrBeyondEitherEdgeIsNoOp() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tempo: 120, tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        doc.splitAudioRegion(id: region.id, atBeat: 0, tempo: 120, inTrackAt: 0)   // at the start edge
        doc.splitAudioRegion(id: region.id, atBeat: 4, tempo: 120, inTrackAt: 0)   // at the end edge
        doc.splitAudioRegion(id: region.id, atBeat: 10, tempo: 120, inTrackAt: 0)  // beyond the end

        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
    }

    func testUndoSplitAudioRegionRestoresOriginalInOneStep() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tempo: 120, tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        doc.splitAudioRegion(id: region.id, atBeat: 1, tempo: 120, inTrackAt: 0)
        doc.undoManager.undo()

        let regions = doc.project.tracks[0].audioRegions
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0], region)
    }

    func testRedoSplitAudioRegionReSplitsInOneStep() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tempo: 120, tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        doc.splitAudioRegion(id: region.id, atBeat: 1, tempo: 120, inTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()

        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 2)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectDocumentTests`
Expected: FAIL to build — "value of type 'ProjectDocument' has no member 'splitAudioRegion'".

- [ ] **Step 3: Implement `splitAudioRegion`/`mergeAudioRegions`**

In `Sources/ProjectModel/ProjectDocument.swift`, find:

```swift
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

Replace with (keeping the original method and adding two new ones after it):

```swift
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

    /// Splits the region with `id` into two at `splitBeat`. A no-op if
    /// `splitBeat` doesn't fall strictly inside the region (e.g. a
    /// double-click landed exactly on or past an edge) — never produces a
    /// degenerate zero-length half. Both halves reference the same
    /// `fileName`; no audio file is read, copied, or written. Registered as
    /// a single undo step via `mergeAudioRegions`'s mutual re-registration
    /// (the same idiom `addAudioRegion`/`removeAudioRegion` already use for
    /// their own undo/redo symmetry) — not composed from three chained
    /// `removeAudioRegion`/`addAudioRegion` calls, which would register
    /// three separate undo steps instead of one.
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectDocumentTests`
Expected: PASS (all pre-existing tests plus the 4 new ones).

- [ ] **Step 5: Add the `AppState` wrapper**

In `Sources/MeridianStudioApp/AppState.swift`, find the `applyQuantization()` method (the last method in the class, just before the closing `}`):

```swift
    func applyQuantization() {
        // The same bound `PianoRollView.moveGesture` clamps drags to (its canvas is
        // 800pt at 40 points-per-beat = 20 beats), taken from that view rather than
        // restated here so the two cannot drift apart. Without it, quantizing a note
        // near the canvas edge could push it out of the reachable/scrollable area the
        // exact way an unclamped drag could — invisible, unreachable by scrolling, and
        // unrecoverable, since neither updateNote nor quantizeNotes is undo-registered.
        document.quantizeNotes(gridBeats: quantizeGridBeats, strength: quantizeStrength, maxStartBeat: PianoRollView.canvasBeats, inTrackAt: selectedTrackIndex)
    }
}
```

Replace with:

```swift
    func applyQuantization() {
        // The same bound `PianoRollView.moveGesture` clamps drags to (its canvas is
        // 800pt at 40 points-per-beat = 20 beats), taken from that view rather than
        // restated here so the two cannot drift apart. Without it, quantizing a note
        // near the canvas edge could push it out of the reachable/scrollable area the
        // exact way an unclamped drag could — invisible, unreachable by scrolling, and
        // unrecoverable, since neither updateNote nor quantizeNotes is undo-registered.
        document.quantizeNotes(gridBeats: quantizeGridBeats, strength: quantizeStrength, maxStartBeat: PianoRollView.canvasBeats, inTrackAt: selectedTrackIndex)
    }

    /// Splits the audio region with `id` on the track at `trackIndex` — the
    /// region's *actual* track, supplied explicitly by the caller
    /// (`TimelineView` renders every track at once, unlike `PianoRollView`,
    /// so this can't default to `selectedTrackIndex` the way note edits do).
    func splitAudioRegion(id: UUID, atBeat beat: Double, inTrackAt trackIndex: Int) {
        document.splitAudioRegion(id: id, atBeat: beat, tempo: document.project.tempo, inTrackAt: trackIndex)
    }
}
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests (plus the 4 new ones) still pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Sources/MeridianStudioApp/AppState.swift Tests/ProjectModelTests/ProjectDocumentTests.swift
git commit -m "Add splitAudioRegion: one undo-registered step for a region split"
```

---

### Task 4: Trim undo + the pre-existing note-undo fix

**Files:**
- Modify: `Sources/ProjectModel/ProjectDocument.swift` (add `updateAudioRegion`, `commitAudioRegionEdit`, `commitNoteEdit`)
- Modify: `Sources/MeridianStudioApp/AppState.swift` (add wrappers)
- Modify: `Sources/MeridianStudioApp/PianoRollView.swift` (wire `commitNoteEdit` into both gestures' `onEnded`)
- Test: `Tests/ProjectModelTests/ProjectDocumentTests.swift`

**Interfaces:**
- Consumes: nothing new from earlier tasks (independent of Tasks 1-3's specifics, though logically parallel to Task 3's undo idiom).
- Produces: `ProjectDocument.updateAudioRegion(_:inTrackAt:)`, `ProjectDocument.commitAudioRegionEdit(from:inTrackAt:)`, `ProjectDocument.commitNoteEdit(from:inTrackAt:)`, and `AppState` wrappers `updateAudioRegion(_:inTrackAt:)`, `commitAudioRegionEdit(from:inTrackAt:)`, `commitNoteEdit(from:)` — all consumed by Task 6's `TimelineView` (the audio ones) and this task's own `PianoRollView` wiring (the note one).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ProjectModelTests/ProjectDocumentTests.swift`, after the four split tests Task 3 added:

```swift
    func testUpdateAudioRegionChangesFieldsWithNoUndoRegistered() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        var updated = region
        updated.lengthBeats = 2
        doc.updateAudioRegion(updated, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].lengthBeats, 2)
        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testCommitAudioRegionEditRegistersNoUndoWhenUnchanged() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        doc.commitAudioRegionEdit(from: region, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testCommitAudioRegionEditRegistersOneUndoStepForTheWholeGesture() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        // Simulate several onChanged frames during one drag, then one commit
        // with the pre-drag value — matches how TimelineView will call this.
        var updated = region
        updated.lengthBeats = 3
        doc.updateAudioRegion(updated, inTrackAt: 0)
        updated.lengthBeats = 2
        doc.updateAudioRegion(updated, inTrackAt: 0)
        doc.commitAudioRegionEdit(from: region, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].lengthBeats, 2)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].lengthBeats, 4, "one undo should restore the pre-drag value, regardless of how many onChanged frames happened in between")
    }

    func testRedoAudioRegionEditReappliesChange() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        var updated = region
        updated.lengthBeats = 2
        doc.updateAudioRegion(updated, inTrackAt: 0)
        doc.commitAudioRegionEdit(from: region, inTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()

        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].lengthBeats, 2)
    }

    func testCommitNoteEditRegistersNoUndoWhenUnchanged() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.commitNoteEdit(from: note, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testCommitNoteEditRegistersOneUndoStepAndRedoes() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        var updated = note
        updated.pitch = 64
        doc.updateNote(updated, inTrackAt: 0)
        doc.commitNoteEdit(from: note, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].pitch, 64)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].pitch, 60)
        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].pitch, 64)
    }

    // Review Focus: sequential edits of different kinds must each undo
    // independently, in reverse order, not merge into one step. This also
    // serves as an empirical check of UndoManager's grouping behavior in a
    // synchronous test run — if it fails, the likely fix is wrapping each
    // commit/split in explicit beginUndoGrouping()/endUndoGrouping().
    func testSequentialTrimThenSplitEachUndoIndependently() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tempo: 120, tracks: [Track(name: "Guitar", kind: .audio, audioRegions: [region])]))

        var trimmed = region
        trimmed.lengthBeats = 3
        doc.updateAudioRegion(trimmed, inTrackAt: 0)
        doc.commitAudioRegionEdit(from: region, inTrackAt: 0)

        doc.splitAudioRegion(id: region.id, atBeat: 1, tempo: 120, inTrackAt: 0)
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 2)

        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].lengthBeats, 3, "undoing the split must not also undo the earlier trim")

        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].lengthBeats, 4)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectDocumentTests`
Expected: FAIL to build — "value of type 'ProjectDocument' has no member 'updateAudioRegion'" (and similarly for `commitAudioRegionEdit`/`commitNoteEdit`).

- [ ] **Step 3: Implement**

In `Sources/ProjectModel/ProjectDocument.swift`, find the `updateNote` method:

```swift
    public func updateNote(_ note: NoteEvent, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == note.id }) else { return }
        project.tracks[trackIndex].regions[regionIndex].notes[noteIndex] = note
    }
```

Replace with (keeping `updateNote` exactly as it is — no undo, called every `onChanged` frame — and adding `commitNoteEdit` after it):

```swift
    public func updateNote(_ note: NoteEvent, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == note.id }) else { return }
        project.tracks[trackIndex].regions[regionIndex].notes[noteIndex] = note
    }

    /// Called once, at drag-end, with the note's value captured when the
    /// drag started. Registers one undo step for the whole gesture —
    /// restoring `original` via the same mutual-re-registration idiom
    /// `addRegion`/`removeRegion` already use, so redo works symmetrically.
    /// `updateNote` itself stays undo-free on purpose: it's called on every
    /// `onChanged` frame during a drag, and registering undo there would
    /// turn one drag gesture into dozens of undo steps.
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

Then, in the same file, find `splitAudioRegion`/`mergeAudioRegions` (added by Task 3) and add the audio-region equivalent right after `mergeAudioRegions`'s closing brace:

```swift
    /// Live setter for the drag in progress — no undo registration, same
    /// reasoning as `updateNote`. Called on every `onChanged` frame.
    public func updateAudioRegion(_ region: AudioRegion, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == region.id }) else { return }
        project.tracks[trackIndex].audioRegions[index] = region
    }

    /// Called once, at drag-end, with the region's value captured when the
    /// drag started. Registers one undo step for the whole gesture, mirroring
    /// `commitNoteEdit`.
    public func commitAudioRegionEdit(from original: AudioRegion, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == original.id }) else { return }
        let current = project.tracks[trackIndex].audioRegions[index]
        guard current != original else { return }
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.updateAudioRegion(original, inTrackAt: trackIndex)
                doc.commitAudioRegionEdit(from: current, inTrackAt: trackIndex)
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectDocumentTests`
Expected: PASS (all pre-existing tests plus the 7 new ones). If `testSequentialTrimThenSplitEachUndoIndependently` fails, see the Review Focus note above before changing anything else.

- [ ] **Step 5: Add the `AppState` wrappers**

In `Sources/MeridianStudioApp/AppState.swift`, find the `splitAudioRegion` wrapper Task 3 added (at the end of the class) and add three more wrappers after it, before the closing `}`:

```swift
    /// Audio-region equivalents of `splitAudioRegion`'s trackIndex handling —
    /// explicit, not `selectedTrackIndex`, since `TimelineView` renders every
    /// track's regions at once.
    func updateAudioRegion(_ region: AudioRegion, inTrackAt trackIndex: Int) {
        document.updateAudioRegion(region, inTrackAt: trackIndex)
    }

    func commitAudioRegionEdit(from original: AudioRegion, inTrackAt trackIndex: Int) {
        document.commitAudioRegionEdit(from: original, inTrackAt: trackIndex)
    }

    /// Unlike the audio-region wrappers above, this one *does* use
    /// `selectedTrackIndex` — matching `moveOrResizeSelectedNote`'s existing
    /// pattern, since `PianoRollView` only ever shows one track's notes at a
    /// time (`selectedTrackIndex`'s track), unlike `TimelineView`.
    func commitNoteEdit(from original: NoteEvent) {
        document.commitNoteEdit(from: original, inTrackAt: selectedTrackIndex)
    }
```

- [ ] **Step 6: Wire `commitNoteEdit` into `PianoRollView`'s drag gestures**

In `Sources/MeridianStudioApp/PianoRollView.swift`, this exact block appears twice — once at the end of `moveGesture`, once at the end of `resizeGesture`:

```swift
            .onEnded { _ in
                dragStartNote = nil
            }
```

Replace **both** occurrences with (identical replacement both times — if using a tool that requires disambiguating repeated matches, `replace_all: true` is correct here since both occurrences get the exact same new text):

```swift
            .onEnded { _ in
                if let dragStartNote { appState.commitNoteEdit(from: dragStartNote) }
                dragStartNote = nil
            }
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 8: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests (plus the 7 new ones) still pass. `testUpdateNoteIsNotUndoRegistered` must still pass unchanged — `updateNote` itself is untouched; only a new sibling method was added.

- [ ] **Step 9: Manual smoke test**

- Drag a MIDI note in the piano roll, then press Undo once — confirm it returns to its pre-drag position/length in one press (this note-editing undo gap didn't exist before this task).

- [ ] **Step 10: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Sources/MeridianStudioApp/AppState.swift Sources/MeridianStudioApp/PianoRollView.swift Tests/ProjectModelTests/ProjectDocumentTests.swift
git commit -m "Add one-step undo for audio-region trim and fix the pre-existing MIDI note-edit undo gap"
```

---

### Task 5: Waveform slicing and file-metadata caching

**Files:**
- Modify: `Sources/AudioEngine/WaveformBands.swift` (add `slice`)
- Modify: `Sources/MeridianStudioApp/AppState.swift` (add `sampleRateCache`, `fileDurationSecondsCache`)
- Modify: `Sources/MeridianStudioApp/AppState+Waveforms.swift` (populate both caches)
- Test: `Tests/AudioEngineTests/WaveformBandsTests.swift`

**Interfaces:**
- Produces: `WaveformBands.slice(fromSeconds:toSeconds:sampleRate:) -> WaveformBands`, `AppState.sampleRateCache: [String: Double]`, `AppState.fileDurationSecondsCache: [String: Double]` — all consumed by Task 6's `TimelineView` (the cache dictionaries are `fileName`-keyed, same as `bandCache`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AudioEngineTests/WaveformBandsTests.swift`, after `testReadOfEmptyFileProducesEmptyBands` (just before the file's closing `}`):

```swift
    func testSliceReturnsTheSubRangeOfBucketsForTheGivenSeconds() {
        // 4 buckets, 512 samples each, at 44100Hz: ~11.6ms/bucket.
        let bands = WaveformBands(low: [0, 1, 2, 3], mid: [10, 11, 12, 13], high: [20, 21, 22, 23])
        let bucketSeconds = Double(WaveformBands.samplesPerBucket) / 44100

        let sliced = bands.slice(fromSeconds: bucketSeconds, toSeconds: bucketSeconds * 3, sampleRate: 44100)

        XCTAssertEqual(sliced.low, [1, 2])
        XCTAssertEqual(sliced.mid, [11, 12])
        XCTAssertEqual(sliced.high, [21, 22])
    }

    func testSliceClampsToTheWholeFileWhenGivenTheFullRange() {
        let bands = WaveformBands(low: [0, 1, 2, 3], mid: [10, 11, 12, 13], high: [20, 21, 22, 23])
        let bucketSeconds = Double(WaveformBands.samplesPerBucket) / 44100

        let sliced = bands.slice(fromSeconds: 0, toSeconds: bucketSeconds * 4, sampleRate: 44100)

        XCTAssertEqual(sliced.low, bands.low)
        XCTAssertEqual(sliced.mid, bands.mid)
        XCTAssertEqual(sliced.high, bands.high)
    }

    func testSliceOfDegenerateRangeReturnsEmptyBands() {
        let bands = WaveformBands(low: [0, 1, 2, 3], mid: [10, 11, 12, 13], high: [20, 21, 22, 23])

        let sliced = bands.slice(fromSeconds: 1, toSeconds: 1, sampleRate: 44100)

        XCTAssertTrue(sliced.low.isEmpty)
        XCTAssertTrue(sliced.mid.isEmpty)
        XCTAssertTrue(sliced.high.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WaveformBandsTests`
Expected: FAIL to build — "value of type 'WaveformBands' has no member 'slice'".

- [ ] **Step 3: Implement `slice`**

In `Sources/AudioEngine/WaveformBands.swift`, find the `write(to:)` method's doc comment and signature:

```swift
    /// Interleaved `Float32` triples (low, mid, high) per bucket — no
```

Insert immediately before it (i.e., right after `bandEnergies`'s closing brace and before this doc comment):

```swift
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WaveformBandsTests`
Expected: PASS (all pre-existing tests plus the 3 new ones).

- [ ] **Step 5: Add the file-metadata caches to `AppState`**

In `Sources/MeridianStudioApp/AppState.swift`, find:

```swift
    var bandLoadsInFlight: Set<String> = []
```

Replace with:

```swift
    var bandLoadsInFlight: Set<String> = []
    /// Each file's sample rate and total duration, keyed by `AudioRegion
    /// .fileName`, populated alongside `bandCache` in `AppState+Waveforms
    /// .swift` — needed to slice a trimmed/split region's waveform
    /// (`sampleRateCache`) and to clamp a trailing trim-handle drag to what
    /// the file actually has left (`fileDurationSecondsCache`).
    @Published var sampleRateCache: [String: Double] = [:]
    @Published var fileDurationSecondsCache: [String: Double] = [:]
```

- [ ] **Step 6: Populate both caches in `AppState+Waveforms.swift`**

In `Sources/MeridianStudioApp/AppState+Waveforms.swift`, find:

```swift
        Task.detached(priority: .utility) {
            let bands = (try? WaveformBands.read(from: bandsFileURL)).flatMap { $0.low.isEmpty ? nil : $0 }
                ?? (try? WaveformBands.analyze(fileURL: audioFileURL))
            guard let bands else { return }
            try? bands.write(to: bandsFileURL)
            await MainActor.run { self.bandCache[region.fileName] = bands }
        }
```

Replace with:

```swift
        Task.detached(priority: .utility) {
            let bands = (try? WaveformBands.read(from: bandsFileURL)).flatMap { $0.low.isEmpty ? nil : $0 }
                ?? (try? WaveformBands.analyze(fileURL: audioFileURL))
            guard let bands else { return }
            try? bands.write(to: bandsFileURL)
            // One extra cheap AVAudioFile header read (not a full re-analysis),
            // whether `bands` came from the cache or a fresh analyze — needed
            // for waveform slicing and the trim-handle clamp, neither of which
            // the `.bandpeaks` cache file itself stores.
            let file = try? AVAudioFile(forReading: audioFileURL)
            let sampleRate = file?.processingFormat.sampleRate
            let durationSeconds = file.map { Double($0.length) / $0.processingFormat.sampleRate }
            await MainActor.run {
                self.bandCache[region.fileName] = bands
                if let sampleRate { self.sampleRateCache[region.fileName] = sampleRate }
                if let durationSeconds { self.fileDurationSecondsCache[region.fileName] = durationSeconds }
            }
        }
```

This file's imports already include `AudioEngine`/`Foundation`/`ProjectModel`; `AVAudioFile` needs `AVFoundation`, so also add that import at the top of `Sources/MeridianStudioApp/AppState+Waveforms.swift`:

```swift
import AudioEngine
import AVFoundation
import Foundation
import ProjectModel
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 8: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests (plus the 3 new ones) still pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/AudioEngine/WaveformBands.swift Sources/MeridianStudioApp/AppState.swift Sources/MeridianStudioApp/AppState+Waveforms.swift Tests/AudioEngineTests/WaveformBandsTests.swift
git commit -m "Add WaveformBands.slice and cache each file's sample rate/duration"
```

---

### Task 6: `TimelineView` — trim handles, split gesture, sliced waveform

**Files:**
- Modify: `Sources/MeridianStudioApp/TimelineView.swift` (full rewrite of the audio-region `ForEach` block, plus new state/gestures)

**Interfaces:**
- Consumes: `AppState.splitAudioRegion(id:atBeat:inTrackAt:)` (Task 3), `AppState.updateAudioRegion(_:inTrackAt:)`/`commitAudioRegionEdit(from:inTrackAt:)` (Task 4), `WaveformBands.slice(fromSeconds:toSeconds:sampleRate:)`, `AppState.sampleRateCache`/`fileDurationSecondsCache` (Task 5).
- Produces: nothing consumed by a later task — this is the final integration task.

No automated tests for this task — matches this project's established precedent that no SwiftUI view code has automated tests anywhere in this codebase. Verified by build and the manual smoke test in Step 3.

- [ ] **Step 1: Add shared state and constants**

In `Sources/MeridianStudioApp/TimelineView.swift`, find:

```swift
struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let laneHeight: CGFloat = 60
```

Replace with:

```swift
struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let laneHeight: CGFloat = 60
    private let resizeHandleWidth: CGFloat = 6
    // Matches PianoRollView.minimumNoteLengthBeats — same floor, same reason:
    // a region/note this short is indistinguishable from zero-length and not
    // worth representing.
    private let minimumRegionLengthBeats: Double = 0.0625
    // Captured once per drag gesture (leading or trailing trim handle), the
    // same way PianoRollView's `dragStartNote` works — the pre-drag value to
    // restore if the whole gesture gets committed to undo.
    @State private var dragStartRegion: AudioRegion?
```

- [ ] **Step 2: Replace the audio-region `ForEach` block**

In `Sources/MeridianStudioApp/TimelineView.swift`, find:

```swift
                        ForEach(track.audioRegions) { region in
                            Rectangle()
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
                                .overlay {
                                    if let bands = appState.waveformBands(for: region) {
                                        WaveformView(bands: bands)
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    Text("Audio").font(.caption2).padding(2)
                                }
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                        }
```

Replace with:

```swift
                        ForEach(track.audioRegions) { region in
                            Rectangle()
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
                                .overlay {
                                    if let bands = appState.waveformBands(for: region), let sampleRate = appState.sampleRateCache[region.fileName] {
                                        let durationSeconds = Tempo.seconds(forBeats: region.lengthBeats, tempo: appState.document.project.tempo)
                                        WaveformView(bands: bands.slice(fromSeconds: region.sourceOffsetSeconds, toSeconds: region.sourceOffsetSeconds + durationSeconds, sampleRate: sampleRate))
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    Text("Audio").font(.caption2).padding(2)
                                }
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.001))
                                        .frame(width: resizeHandleWidth, height: laneHeight)
                                        .gesture(trimLeadingGesture(for: region, tempo: appState.document.project.tempo, trackIndex: index))
                                }
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.001))
                                        .frame(width: resizeHandleWidth, height: laneHeight)
                                        .gesture(trimTrailingGesture(for: region, tempo: appState.document.project.tempo, trackIndex: index, fileDurationSeconds: appState.fileDurationSecondsCache[region.fileName]))
                                }
                                .gesture(
                                    SpatialTapGesture(count: 2)
                                        .onEnded { value in
                                            let clickedBeat = region.startBeat + Double(value.location.x / pixelsPerBeat)
                                            if clickedBeat > region.startBeat + minimumRegionLengthBeats,
                                               clickedBeat < region.startBeat + region.lengthBeats - minimumRegionLengthBeats {
                                                appState.splitAudioRegion(id: region.id, atBeat: clickedBeat, inTrackAt: index)
                                            }
                                        }
                                )
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                        }
```

(`index` is already in scope here — the outer `ForEach(Array(appState.document.project.tracks.enumerated()), id: \.element.id) { index, track in` this block lives inside.)

- [ ] **Step 3: Add the two trim gestures**

In `Sources/MeridianStudioApp/TimelineView.swift`, add after `maxEndBeat(for:)` (and before `var body`):

```swift
    // Both gestures measure translation in `.global`, matching
    // `PianoRollView`'s drag gestures exactly — same reasoning: these
    // gestures move the very view they're attached to, so a local origin
    // would shift underneath the in-flight drag.
    private func trimLeadingGesture(for region: AudioRegion, tempo: Double, trackIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartRegion ?? region
                if dragStartRegion == nil { dragStartRegion = region }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                // Dragging right (positive delta) can't shrink the region
                // below minimumRegionLengthBeats; dragging left (negative
                // delta) can't push sourceOffsetSeconds below 0 — there's no
                // audio before the file's own start.
                let maxDeltaBeats = start.lengthBeats - minimumRegionLengthBeats
                let minDeltaBeats = -Tempo.beats(forSeconds: start.sourceOffsetSeconds, tempo: tempo)
                let clampedDeltaBeats = min(max(deltaBeats, minDeltaBeats), maxDeltaBeats)
                var updated = start
                updated.startBeat = start.startBeat + clampedDeltaBeats
                updated.lengthBeats = start.lengthBeats - clampedDeltaBeats
                updated.sourceOffsetSeconds = start.sourceOffsetSeconds + Tempo.seconds(forBeats: clampedDeltaBeats, tempo: tempo)
                appState.updateAudioRegion(updated, inTrackAt: trackIndex)
            }
            .onEnded { _ in
                if let dragStartRegion { appState.commitAudioRegionEdit(from: dragStartRegion, inTrackAt: trackIndex) }
                dragStartRegion = nil
            }
    }

    // `fileDurationSeconds` is nil only on the first render before
    // `AppState+Waveforms.swift`'s loader has populated the cache — in that
    // narrow window this just doesn't clamp against the file's length yet
    // (the playback-time clamp in `PlaybackEngine` is the backstop either
    // way, matching how `waveformBands(for:)` itself already tolerates
    // returning nil on first render).
    private func trimTrailingGesture(for region: AudioRegion, tempo: Double, trackIndex: Int, fileDurationSeconds: Double?) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartRegion ?? region
                if dragStartRegion == nil { dragStartRegion = region }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                var maxLengthBeats = Double.infinity
                if let fileDurationSeconds {
                    let remainingSeconds = max(fileDurationSeconds - start.sourceOffsetSeconds, 0)
                    maxLengthBeats = Tempo.beats(forSeconds: remainingSeconds, tempo: tempo)
                }
                var updated = start
                updated.lengthBeats = min(max(start.lengthBeats + deltaBeats, minimumRegionLengthBeats), maxLengthBeats)
                appState.updateAudioRegion(updated, inTrackAt: trackIndex)
            }
            .onEnded { _ in
                if let dragStartRegion { appState.commitAudioRegionEdit(from: dragStartRegion, inTrackAt: trackIndex) }
                dragStartRegion = nil
            }
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests still pass — this task adds none.

- [ ] **Step 6: Manual smoke test**

- Drag a region's trailing handle shorter, then longer — confirm it won't extend past what the source file actually has left (Review Focus item), and confirm playback matches what's shown.
- Drag a region's leading handle right (trimming from the start) — confirm the region's left edge moves right, the right edge stays put, and playback starts further into the file. Drag it back left to un-trim, down to the original full length.
- Double-click a region away from its edges — confirm it splits into two, each showing only its own slice of the waveform (not the whole file's shape squeezed into a shorter width), and both play back correctly.
- Double-click very close to a trim handle (within a few pixels) — confirm it still splits rather than being swallowed by the handle's drag gesture, and confirm dragging a handle doesn't accidentally register as a double-click (this project doesn't have an automated way to verify SwiftUI gesture-overlap behavior, so this is the check that catches it if the two gestures interfere).
- Undo/redo a trim (one press each direction) and a split (one press each direction).
- Open a project saved before this milestone and confirm its existing audio regions still play and render exactly as before (every field defaults correctly: `sourceOffsetSeconds == 0`).

- [ ] **Step 7: Commit**

```bash
git add Sources/MeridianStudioApp/TimelineView.swift
git commit -m "Add trim handles and double-click-to-split to the timeline, with sliced waveform rendering"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** §1 (scope, including the two discovered-during-design prerequisite fixes) → Task 2 (playback/resolution fix) and the plan's framing throughout. §2 (data model) → Task 1, verbatim from the spec. §3 (playback) → Task 2, verbatim. §4 (split) → Task 3, verbatim. §5 (trim + the note-undo fix) → Task 4 (undo methods) and Task 6 (the actual drag gestures, with one real fix beyond the spec — see below). §6 (waveform slicing) → Task 5, verbatim, plus Task 6's call site. §7 (testing) → every task's own tests, plus the cross-cutting Review Focus items. §8 (non-goals) → nothing in any task exceeds them.
- **A real gap found and fixed during planning, not just transcribed from the spec:** the spec's §5 trailing-handle sketch only clamped length against `minimumRegionLengthBeats`, with no bound against the file's actual remaining duration — meaning a user could drag a region's stored `lengthBeats` longer than the audio behind it, and `PlaybackEngine`'s defensive clamp (meant only for a corrupt file) would silently truncate playback without the displayed region shrinking to match. Task 5 adds a `fileDurationSecondsCache` (alongside the already-planned `sampleRateCache`, same cheap file-header read) and Task 6's `trimTrailingGesture` clamps against it — now a Review Focus item with its own line.
- **A second gap found and fixed:** the spec's wrapper methods were described only in prose ("`AppState` gains a thin wrapper..."), which glossed over a real question — should audio-region wrappers use `selectedTrackIndex` (mirroring `moveOrResizeSelectedNote`) or take an explicit `trackIndex`? Checked: `PianoRollView` only ever shows `selectedTrackIndex`'s own notes, so `commitNoteEdit`'s implicit-selection pattern is correct for notes. `TimelineView` renders *every* track's regions simultaneously, so an implicit `selectedTrackIndex` would silently misfire whenever a user drags/splits a region on a track that isn't currently selected. Task 4/Task 3's audio-region wrappers take `trackIndex` explicitly; only `commitNoteEdit` uses `selectedTrackIndex`, and Task 4's doc comments say why.
- **Placeholder scan:** no TBD/TODO; every task gives complete, verbatim code and exact find/replace snippets.
- **Type consistency:** `AudioRegion.sourceOffsetSeconds`/its `init` (Task 1) is used identically in Tasks 2-6. `ProjectDocument.splitAudioRegion(id:atBeat:tempo:inTrackAt:)` (Task 3) and `updateAudioRegion`/`commitAudioRegionEdit`/`commitNoteEdit` (Task 4) are used with identical names/signatures in their `AppState` wrappers and (for the audio ones) Task 6's `TimelineView`. `WaveformBands.slice(fromSeconds:toSeconds:sampleRate:)` and `AppState.sampleRateCache`/`fileDurationSecondsCache` (Task 5) are used identically in Task 6. `PlaybackEngine.play`'s new tuple shape (Task 2) matches `resolveAudioRegions`'s return type exactly (both changed together, same task).
- **Task-boundary buildability:** every task (1-5) is purely additive — new fields with defaults, new methods, no renames or deletions of anything another not-yet-updated file depends on — so each leaves `swift build`/`swift test` green on its own, the same discipline the multiband-waveform plan's self-review had to retrofit after finding a sequencing bug. Task 6 is the one task that changes existing code (`TimelineView`'s audio-region block), and it depends on every prior task's additions already existing by the time it runs — safe, since it's last.
- **Review Focus:** all 5 items map to a specific task/test — no-op split at edges (Task 3 `testSplitAudioRegionAtOrBeyondEitherEdgeIsNoOp`), no-op commit registers no undo (Task 4 `testCommitAudioRegionEditRegistersNoUndoWhenUnchanged`/`testCommitNoteEditRegistersNoUndoWhenUnchanged`), sequential edits undo independently (Task 4 `testSequentialTrimThenSplitEachUndoIndependently`, flagged as also an empirical UndoManager check), an untrimmed region still plays in full (Task 2 + Task 6 manual smoke test, no automated test per established `PlaybackEngine` precedent), trailing-handle file-bounds clamp (Task 6's `trimTrailingGesture`, using Task 5's `fileDurationSecondsCache`).
