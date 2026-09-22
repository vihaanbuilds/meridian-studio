# Waveform Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render an actual waveform for every `AudioRegion` in the
timeline (recorded or imported), instead of today's plain colored
block.

**Architecture:** A new `WaveformPeaks` type in `AudioEngine` computes
and (de)serializes one peak magnitude per 512-sample bucket, reusing
`AudioLevelMeter.peak(of:)`. A new `AppState+Waveforms.swift`
extension owns an in-memory cache plus a single loader function,
`waveformPeaks(for:)`, that reads a cached `.peaks` file if one
exists, analyzes and writes one if not, and is called from three
places: right after a recording finishes, right after an import
finishes, and (as the lazy backfill for regions from older projects)
from `TimelineView` itself on every render. `TimelineView` overlays a
new `WaveformView` (a SwiftUI `Canvas`) once peaks are available.

**Tech Stack:** Swift 6, SwiftUI (`Canvas`), `AVFoundation`
(`AVAudioFile`, `AVAudioPCMBuffer`) — all already used elsewhere in
this codebase; no new dependency.

**Spec:** `docs/superpowers/specs/2026-09-21-waveform-rendering-design.md`

## Global Constraints

- No changes to `Project`/`AudioRegion`/`Track` or `schemaVersion` —
  the `.peaks` file path is always derived from `AudioRegion.fileName`
  by swapping its extension, never stored as a model field.
- One combined magnitude per 512-sample bucket (`WaveformPeaks
  .samplesPerBucket`), reusing `AudioLevelMeter.peak(of:)` unchanged —
  no new metering algorithm, no per-channel/stereo data.
- The `.peaks` file format has no header and no version field: raw
  `Float32` little-endian values, bucket count = file size / 4. A
  malformed or empty read is treated as "missing" and recomputed.
- `.peaks` files are never actively deleted when a region/track is
  removed — matches this project's existing, already-accepted
  behavior for the audio files themselves.
- `waveformPeaks(for:)` is the **single** function used for both
  creation-time generation (record/import) and lazy backfill
  (pre-existing regions) — no second code path.
- On analysis failure, at most one attempt per file per app session
  (the in-flight set is never cleared on failure) — no retry loop, no
  user-facing alert.
- No automated tests for SwiftUI view code or for `AppState`
  extension files that touch real files/async work — matches this
  project's established precedent. `WaveformPeaks` itself (pure logic
  in `AudioEngine`) is the one piece with unit tests, mirroring
  `AudioLevelMeterTests`.

---

### Task 1: `WaveformPeaks` (AudioEngine)

**Files:**
- Create: `Sources/AudioEngine/WaveformPeaks.swift`
- Test: `Tests/AudioEngineTests/WaveformPeaksTests.swift`

**Interfaces:**
- Consumes: `AudioLevelMeter.peak(of:)` (pre-existing, unmodified).
- Produces: `WaveformPeaks.samplesPerBucket: AVAudioFrameCount`,
  `WaveformPeaks.analyze(fileURL: URL) throws -> WaveformPeaks`,
  `WaveformPeaks(magnitudes: [Float])`, `.magnitudes: [Float]`,
  `.write(to: URL) throws`, `.read(from: URL) throws -> WaveformPeaks`
  (`static`). Used by Task 2's `AppState+Waveforms.swift`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AudioEngineTests/WaveformPeaksTests.swift
import XCTest
import AVFoundation
@testable import AudioEngine

final class WaveformPeaksTests: XCTestCase {
    private func makeTestFile(bucketAmplitudes: [Float]) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for amplitude in bucketAmplitudes {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: WaveformPeaks.samplesPerBucket)!
            buffer.frameLength = WaveformPeaks.samplesPerBucket
            for frame in 0..<Int(WaveformPeaks.samplesPerBucket) {
                buffer.floatChannelData![0][frame] = amplitude
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testAnalyzeProducesOnePeakMagnitudePerBucket() throws {
        let url = try makeTestFile(bucketAmplitudes: [0, 0.5, 1.0, -0.8])
        defer { try? FileManager.default.removeItem(at: url) }

        let peaks = try WaveformPeaks.analyze(fileURL: url)

        XCTAssertEqual(peaks.magnitudes.count, 4)
        XCTAssertEqual(peaks.magnitudes[0], 0, accuracy: 0.0001)
        XCTAssertEqual(peaks.magnitudes[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(peaks.magnitudes[2], 1.0, accuracy: 0.0001)
        XCTAssertEqual(peaks.magnitudes[3], 0.8, accuracy: 0.0001)
    }

    func testWriteAndReadRoundTrip() throws {
        let peaks = WaveformPeaks(magnitudes: [0, 0.25, 0.5, 0.75, 1.0])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).peaks")
        defer { try? FileManager.default.removeItem(at: url) }

        try peaks.write(to: url)
        let readBack = try WaveformPeaks.read(from: url)

        XCTAssertEqual(readBack.magnitudes, peaks.magnitudes)
    }

    func testReadOfEmptyFileProducesEmptyMagnitudes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).peaks")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let peaks = try WaveformPeaks.read(from: url)

        XCTAssertTrue(peaks.magnitudes.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WaveformPeaksTests`
Expected: FAIL to build — "cannot find type 'WaveformPeaks' in scope"
(the type doesn't exist yet).

- [ ] **Step 3: Implement `WaveformPeaks`**

```swift
// Sources/AudioEngine/WaveformPeaks.swift
import AVFoundation

/// One peak magnitude per fixed-size bucket of an audio file, for
/// rendering a waveform. Reuses `AudioLevelMeter.peak(of:)`'s "largest
/// absolute sample value across every channel and frame" convention,
/// applied per bucket instead of per whole buffer — one combined value,
/// not per-channel/stereo.
public struct WaveformPeaks: Sendable {
    public static let samplesPerBucket: AVAudioFrameCount = 512

    public let magnitudes: [Float]

    public init(magnitudes: [Float]) {
        self.magnitudes = magnitudes
    }

    /// Reads `fileURL` in fixed `samplesPerBucket`-frame chunks.
    public static func analyze(fileURL: URL) throws -> WaveformPeaks {
        let file = try AVAudioFile(forReading: fileURL)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: samplesPerBucket) else {
            return WaveformPeaks(magnitudes: [])
        }
        var magnitudes: [Float] = []
        while true {
            try file.read(into: buffer, frameCount: samplesPerBucket)
            guard buffer.frameLength > 0 else { break }
            magnitudes.append(AudioLevelMeter.peak(of: buffer))
        }
        return WaveformPeaks(magnitudes: magnitudes)
    }

    /// Raw `Float32` array, no header, no version field: this is
    /// regenerable cache data, not user content. `read(from:)` treats any
    /// malformed or empty result as "missing" rather than failing loudly.
    public func write(to url: URL) throws {
        let data = magnitudes.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> WaveformPeaks {
        let data = try Data(contentsOf: url)
        let count = data.count / MemoryLayout<Float>.size
        let magnitudes = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
        return WaveformPeaks(magnitudes: magnitudes)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WaveformPeaksTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests still pass alongside the 3 new ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/AudioEngine/WaveformPeaks.swift Tests/AudioEngineTests/WaveformPeaksTests.swift
git commit -m "Add WaveformPeaks: per-bucket peak analysis and .peaks file (de)serialization"
```

---

### Task 2: Peaks Cache/Loader, Wired Into Record and Import

**Files:**
- Modify: `Sources/MeridianStudioApp/AppState.swift`
- Create: `Sources/MeridianStudioApp/AppState+Waveforms.swift`
- Modify: `Sources/MeridianStudioApp/AppState+AudioRecording.swift`
- Modify: `Sources/MeridianStudioApp/AppState+AudioImport.swift`

**Interfaces:**
- Consumes: `WaveformPeaks.analyze(fileURL:)`/`.write(to:)`/
  `.read(from:)` (Task 1). `AppState.fileURL` (pre-existing).
- Produces: `AppState.waveformPeaks(for: AudioRegion) -> WaveformPeaks?`
  — used by Task 3's `TimelineView`, and by this task's own two call
  sites in `stopAudioRecording()`/`importAudio(from:toTrackAt:)`.

No automated tests for this task — matches this project's established
precedent for `AppState`-file-I/O-and-async-driven code
(`AppState+AudioImport.swift`/`AppState+AudioRecording.swift` have
none either). Verified by build, the full test suite (regression
only), and Task 3's manual smoke test, which is the first point this
becomes observable end-to-end.

- [ ] **Step 1: Add cache properties to `AppState.swift`**

In `Sources/MeridianStudioApp/AppState.swift`, find:

```swift
    /// Live output level while anything (MIDI or audio) is playing back. Reads
    /// naturally as 0 when nothing is scheduled — the tap receives silence.
    @Published private(set) var outputLevel: Float = 0
```

Add immediately after it:

```swift
    /// Cached waveform peaks for audio regions, keyed by
    /// `AudioRegion.fileName`. Populated by `waveformPeaks(for:)` in
    /// `AppState+Waveforms.swift`, off the main thread — `@Published` so
    /// `TimelineView` redraws once a load completes. Not `private`: both
    /// this file and `AppState+Waveforms.swift` read and write it.
    @Published var waveformCache: [String: WaveformPeaks] = [:]
    /// Dedupes concurrent loads for the same file. Never cleared on
    /// failure — see `AppState+Waveforms.swift` for why that's
    /// intentional (at most one analysis attempt per file per session).
    var waveformLoadsInFlight: Set<String> = []
```

`AppState.swift` already has `import AudioEngine` (for `PlaybackEngine`
etc.), so `WaveformPeaks` resolves with no new import.

- [ ] **Step 2: Create `AppState+Waveforms.swift`**

```swift
// Sources/MeridianStudioApp/AppState+Waveforms.swift
import AudioEngine
import Foundation

extension AppState {
    /// Returns cached peaks for `region` if already loaded, and kicks off a
    /// background load (a cached `.peaks` file, or a fresh analysis) if
    /// not. Callers simply re-invoke on every render; the `@Published`
    /// cache write on completion triggers the redraw that shows the
    /// result. Also the single call site used to generate peaks right
    /// after a recording or import finishes — same function, whether this
    /// is a brand-new region or an older one seen for the first time.
    func waveformPeaks(for region: AudioRegion) -> WaveformPeaks? {
        if let cached = waveformCache[region.fileName] { return cached }
        guard waveformLoadsInFlight.insert(region.fileName).inserted, let fileURL else { return nil }
        let audioDirectory = fileURL.appendingPathComponent("audio")
        let audioFileURL = audioDirectory.appendingPathComponent(region.fileName)
        let peaksFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("peaks")
        Task.detached(priority: .utility) {
            let peaks = (try? WaveformPeaks.read(from: peaksFileURL)).flatMap { $0.magnitudes.isEmpty ? nil : $0 }
                ?? (try? WaveformPeaks.analyze(fileURL: audioFileURL))
            guard let peaks else { return }
            try? peaks.write(to: peaksFileURL)
            await MainActor.run { self.waveformCache[region.fileName] = peaks }
        }
        return nil
    }
}
```

- [ ] **Step 3: Wire into `stopAudioRecording()`**

In `Sources/MeridianStudioApp/AppState+AudioRecording.swift`, find:

```swift
        do {
            try FileManager.default.moveItem(at: workingURL, to: finalURL)
            document.addAudioRegion(region, toTrackAt: selectedTrackIndex)
        } catch {
            presentError(error)
        }
```

Replace with:

```swift
        do {
            try FileManager.default.moveItem(at: workingURL, to: finalURL)
            document.addAudioRegion(region, toTrackAt: selectedTrackIndex)
            _ = waveformPeaks(for: region)
        } catch {
            presentError(error)
        }
```

- [ ] **Step 4: Wire into `importAudio(from:toTrackAt:)`**

In `Sources/MeridianStudioApp/AppState+AudioImport.swift`, find:

```swift
        let region = AudioRegion(startBeat: startBeat, lengthBeats: max(lengthBeats, 0.1), fileName: destinationFileName)
        document.addAudioRegion(region, toTrackAt: trackIndex)
    }
}
```

Replace with:

```swift
        let region = AudioRegion(startBeat: startBeat, lengthBeats: max(lengthBeats, 0.1), fileName: destinationFileName)
        document.addAudioRegion(region, toTrackAt: trackIndex)
        _ = waveformPeaks(for: region)
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests (plus Task 1's 3 new ones) still
pass — this task adds no new tests of its own.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeridianStudioApp/AppState.swift Sources/MeridianStudioApp/AppState+Waveforms.swift Sources/MeridianStudioApp/AppState+AudioRecording.swift Sources/MeridianStudioApp/AppState+AudioImport.swift
git commit -m "Generate and cache waveform peaks on record/import, via a reusable loader"
```

---

### Task 3: `WaveformView` and `TimelineView` Integration

**Files:**
- Create: `Sources/MeridianStudioApp/WaveformView.swift`
- Modify: `Sources/MeridianStudioApp/TimelineView.swift`

**Interfaces:**
- Consumes: `AppState.waveformPeaks(for:)` (Task 2) —  this is also
  the point where a region from a project saved before this milestone
  gets its lazy backfill, with no extra code: `TimelineView` calling
  this on every render for every visible region *is* the backfill
  path. `WaveformPeaks.magnitudes: [Float]` (Task 1).
- Produces: `WaveformView(peaks: WaveformPeaks)` — a `View`. Not
  consumed by any other task in this plan.

No automated tests for this task — matches this project's established
precedent that no SwiftUI view code has automated tests anywhere in
this codebase. Verified by build and the manual smoke test in Step 3.

- [ ] **Step 1: Create `WaveformView.swift`**

```swift
// Sources/MeridianStudioApp/WaveformView.swift
import AudioEngine
import SwiftUI

/// Renders `peaks` as a mirrored bar per bucket, stretched to fill the
/// view's width — one combined magnitude per bucket, not per-channel.
struct WaveformView: View {
    let peaks: WaveformPeaks

    var body: some View {
        Canvas { context, size in
            guard !peaks.magnitudes.isEmpty else { return }
            let midY = size.height / 2
            let barWidth = size.width / CGFloat(peaks.magnitudes.count)
            var path = Path()
            for (index, magnitude) in peaks.magnitudes.enumerated() {
                let x = CGFloat(index) * barWidth
                let barHeight = CGFloat(min(magnitude, 1)) * midY
                path.addRect(CGRect(x: x, y: midY - barHeight, width: max(barWidth, 0.5), height: barHeight * 2))
            }
            context.fill(path, with: .color(.white.opacity(0.85)))
        }
    }
}
```

- [ ] **Step 2: Overlay it on audio regions in `TimelineView`**

In `Sources/MeridianStudioApp/TimelineView.swift`, add `AudioEngine` to
the imports at the top of the file:

```swift
import AudioEngine
import ProjectModel
import SwiftUI
```

Then find the audio-region block:

```swift
                        ForEach(track.audioRegions) { region in
                            Rectangle()
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
                                .overlay(alignment: .topLeading) {
                                    Text("Audio").font(.caption2).padding(2)
                                }
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                        }
```

Replace with (adding the waveform overlay *before* `.offset()`, same
as the existing caption overlay — `.offset()` must stay the last
modifier in the chain, or the overlay positions against the region's
pre-offset frame, the exact bug already found and fixed once in this
file during the audio-import milestone):

```swift
                        ForEach(track.audioRegions) { region in
                            Rectangle()
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
                                .overlay {
                                    if let peaks = appState.waveformPeaks(for: region) {
                                        WaveformView(peaks: peaks)
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    Text("Audio").font(.caption2).padding(2)
                                }
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                        }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests (plus Task 1's 3 new ones) still
pass — this task adds no new tests.

- [ ] **Step 5: Manual smoke test**

Check (in addition to everything from prior milestones'
smoke-test checklists):

- Record a short audio take. Once it stops, the region in the
  timeline shows an actual waveform shape, not a flat block.
- Import an existing `.wav` file. Same — a waveform appears, not a
  flat block.
- Quit and reopen the project. The waveform for both regions
  reappears immediately (no visible delay/flicker), confirming it's
  reading the cached `.peaks` file rather than recomputing.
- Open a project saved *before* this milestone (or manually delete an
  `audio/<uuid>.peaks` file next to an existing region's audio file,
  then reopen). Confirm the region still renders a waveform shortly
  after appearing — the lazy-backfill path — and that a `.peaks` file
  now exists next to the audio file.
- Confirm an audio region with `startBeat > 0` still renders its
  waveform (and caption) at the correct offset position, not pinned to
  the lane's left edge — regression check for the offset-ordering bug
  class this step's diff is careful to avoid reintroducing.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeridianStudioApp/WaveformView.swift Sources/MeridianStudioApp/TimelineView.swift
git commit -m "Render waveforms for audio regions in the timeline"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** §2 (peak data & file format) → Task 1, verbatim.
  §3 (generation & caching, including the "one shared function" and
  "never cleared on failure" requirements) → Task 2, verbatim. §4
  (rendering, including the `.offset()`-ordering care) → Task 3,
  verbatim. §5 (testing) → reflected in each task's "no automated
  tests" note plus Task 1's actual unit tests and Task 3's manual
  smoke test. §6 (non-goals) → nothing in any task exceeds them. No
  gaps found.
- **Placeholder scan:** no TBD/TODO; all three tasks give complete,
  verbatim code and exact find/replace snippets.
- **Type consistency:** `WaveformPeaks.samplesPerBucket` /
  `.analyze(fileURL:)` / `.magnitudes` / `.write(to:)` / `.read(from:)`
  (Task 1) are used with identical names and signatures in Task 2's
  loader. `AppState.waveformPeaks(for:) -> WaveformPeaks?` (Task 2) is
  used with the identical name and signature at all three of its call
  sites: Task 2's own `stopAudioRecording()`/`importAudio(from:
  toTrackAt:)`, and Task 3's `TimelineView`. `WaveformView(peaks:)`
  (Task 3) is defined and consumed within the same task, no mismatch.
