# Waveform Rendering — Design

Date: 2026-09-21
Status: Approved
Phase: 3 (third milestone)

## 1. Scope

The audio-import milestone's own spec explicitly deferred this:
"Waveform rendering (still the later milestone's job — regions render
as plain colored blocks, matching how recorded regions already do)."
This milestone is that later milestone — nothing more.

Every `AudioRegion` in the timeline (recorded or imported) renders an
actual visual of its waveform, not just a flat colored block.

Deliberately out of scope, same "smallest useful slice" discipline
every prior milestone in this project has used:

- Zoom-aware resolution (the timeline has no zoom feature yet;
  `pixelsPerBeat` is a fixed constant).
- Stereo/per-channel display — one combined waveform per region,
  matching `AudioLevelMeter`'s existing "across every channel"
  convention.
- Click-to-seek or any other interaction with the waveform.
- Any change to the live level meter shown while recording — that
  stays exactly as it is.
- Trim/split/fade/normalize (the milestones after this one).

## 2. Peak Data & File Format

A new `WaveformPeaks` type in `AudioEngine`, alongside `AudioRecorder`,
`PlaybackEngine`, and `AudioLevelMeter`:

```swift
// Sources/AudioEngine/WaveformPeaks.swift
import AVFoundation

public struct WaveformPeaks: Sendable {
    public static let samplesPerBucket: AVAudioFrameCount = 512

    public let magnitudes: [Float]

    public init(magnitudes: [Float]) {
        self.magnitudes = magnitudes
    }

    /// Reads `fileURL` in fixed `samplesPerBucket`-frame chunks, reusing
    /// `AudioLevelMeter.peak(of:)` per chunk — the same "largest absolute
    /// sample value across every channel and frame" convention the level
    /// meter already established, applied per bucket instead of per whole
    /// buffer.
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

512 samples/bucket gives roughly 86–94 buckets/second at typical
44.1/48kHz sample rates — enough resolution for a lane-height waveform
without an unreasonable file size (4 bytes/bucket: a 30-second take is
~10KB).

The file is a raw `Float32` array with **no header and no version
field** — deliberately. This is fully regenerable cache data, not user
content: if a read ever comes back malformed or empty, the loader
below treats it as missing and recomputes, so there is no migration
path to maintain. Documented trade-off: if a later milestone changes
`samplesPerBucket`, an old `.peaks` file is still a "valid" read at the
old resolution — cosmetic only (a coarser/finer bar spacing until the
region is touched again), not a correctness bug, and not worth a
version field to prevent.

Stored at `audio/<uuid>.peaks`, the same UUID basename as
`audio/<uuid>.<ext>`, derived from `AudioRegion.fileName` by swapping
the extension. **No `AudioRegion`/`Project` schema change, no
`schemaVersion` bump** — this milestone is achievable entirely through
`AudioEngine` + app-layer additions, matching the audio-import
milestone's precedent of leaving `ProjectModel` untouched where
possible.

## 3. Generation & Caching

- **New region** (record-stop, import): peaks are computed right after
  the audio file is finalized/copied, and the `.peaks` file is written
  immediately — the same moment `AppState+AudioRecording`/
  `AppState+AudioImport` already compute duration via `AVAudioFile`.
- **Older region** with no `.peaks` file yet (a project saved before
  this milestone): computed lazily on first appearance in the
  timeline, then written out — same function, same file, no distinct
  code path.
- `.peaks` files are **never actively deleted** when a region or track
  is removed. This matches this project's existing, already-accepted
  behavior for the audio files themselves — `removeAudioRegion`/
  `removeTrack` are in-memory, undo-registered model operations that
  have never touched disk files (see `docs/architecture.md`), so a
  `.peaks` file left behind is not a new orphan problem this milestone
  introduces. They ride along for free on Save As, since
  `ProjectStore.copyAudioFiles` already copies every file under
  `audio/` generically regardless of extension.

New extension file, mirroring `AppState+AudioRecording.swift`'s shape:

```swift
// Sources/MeridianStudioApp/AppState+Waveforms.swift
import AudioEngine
import Foundation

extension AppState {
    /// Returns cached peaks for `region` if already loaded, and kicks off a
    /// background load (cached `.peaks` file, or a fresh analysis) if not.
    /// Callers simply re-invoke on every render; the `@Published` cache
    /// write on completion triggers the redraw that shows the result.
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

`waveformCache: [String: WaveformPeaks]` (`@Published`, keyed by
`fileName`) and `waveformLoadsInFlight: Set<String>` (plain, dedupes
concurrent loads for the same file) are added to `AppState.swift`'s
existing property list, next to `inputLevel`/`outputLevel` — state
lives in `AppState.swift`, feature logic in the extension file, the
same split `AppState`/`AppState+AudioRecording` already uses.

No alert on analysis failure (corrupt file, empty buffer): the region
just keeps rendering as today's plain colored block. This is a
rendering nicety, not a data-integrity operation — matches the existing
low-ceremony precedent `AudioLevelMeter` set ("pure and hardware-free,"
no error surface of its own).

`waveformLoadsInFlight` is never cleared on failure, so a file whose
analysis fails gets **at most one attempt per app session** — later
render calls see it already marked in-flight and return `nil`
indefinitely rather than retrying every redraw. Deliberate: retrying a
failure that isn't going to start succeeding would just burn a
background task on every render for no benefit. A relaunch (or fixing
the underlying file) is what clears it.

## 4. Rendering

```swift
// Sources/MeridianStudioApp/WaveformView.swift
import AudioEngine
import SwiftUI

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

`TimelineView`'s audio-region block gains a `WaveformView` overlay,
shown once peaks are cached:

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

`.offset()` stays the **last** modifier in the chain, both `.overlay`
calls before it — the exact ordering the audio-import milestone had to
fix for the region's caption label (`.offset()` is layout-transparent;
anything chained after it positions against the pre-offset frame). This
new overlay is added in the already-correct position, not reintroducing
that bug.

## 5. Testing

- Unit tests for `WaveformPeaks.analyze`/`write`/`read` round-trip in
  `AudioEngineTests`, using a synthetic generated WAV (silence, plus a
  sine ramp with a known peak) written to a temp file — pure
  file-analysis logic, not hardware-adjacent, so it's testable the same
  way `AudioLevelMeterTests` already is.
- No test for the `Canvas` rendering itself or `AppState+Waveforms`'s
  loader — matches this project's established precedent that no
  SwiftUI view code and no `AppState`-file-I/O-driven code has
  automated coverage (`ProjectDocumentIO.swift`,
  `AppState+AudioImport.swift` have none either, for the same reason).
- Manual smoke test, added to the standing checklist: record and
  import audio and confirm a waveform appears (not just a flat block);
  quit and reopen the project and confirm the waveform reappears
  immediately (read from the cached `.peaks` file, not recomputed);
  open a project saved before this milestone and confirm its existing
  audio region still renders a waveform (lazy backfill).

## 6. Non-Goals

- Zoom-aware resolution.
- Stereo/per-channel waveform display.
- Click-to-seek or any other waveform interaction.
- Live waveform during recording (the existing level meter is
  unchanged).
- Trim/split/fade/normalize.
- Any change to Meridian Companion (Meridian Studio-only, per the
  two-app architecture spec).
