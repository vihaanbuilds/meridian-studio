# Multi-Band Waveform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-color waveform drawn for each `AudioRegion` with three overlaid, colored frequency bands (low/bass, mid/vocals, high/cymbals), computed via FFT.

**Architecture:** `WaveformPeaks` (one time-domain peak per bucket) is replaced outright by `WaveformBands` (three FFT-derived band-energy magnitudes per bucket) in `AudioEngine`. The cache/loader shape in `AppState+Waveforms.swift` and the trigger points in `AppState+AudioRecording.swift`/`AppState+AudioImport.swift` stay the same, just renamed and pointed at a new `.bandpeaks` cache file. `WaveformView` draws the same mirrored-bar Canvas technique three times, layered with translucent color per band.

**Tech Stack:** Swift 6, Accelerate (`vDSP` FFT), AVFoundation (`AVAudioFile`, `AVAudioPCMBuffer`), SwiftUI (`Canvas`) — all either already used elsewhere in this codebase or a system framework requiring no `Package.swift` change.

**Spec:** `docs/superpowers/specs/2026-09-29-multiband-waveform-design.md`

## Global Constraints

- No changes to `Project`/`AudioRegion`/`Track` or `schemaVersion`.
- No `Package.swift` change — `Accelerate` is a system framework, linked implicitly the same way `AVFoundation` already is.
- `WaveformPeaks.swift`/`WaveformPeaksTests.swift` are deleted, not kept alongside `WaveformBands` — nothing outside `AppState+Waveforms.swift`, `WaveformView.swift`, and their tests references the old type. Deleted once every consumer has migrated (end of Task 2), not before — deleting it earlier, or renaming `AppState`'s API before its only caller is updated, would leave the build broken for a whole task-commit, and this project's convention is to fix the underlying sequencing rather than paper over it with a temporary compatibility shim.
- The new cache file extension is `.bandpeaks`, never `.peaks` — old `.peaks` files are left orphaned on disk, never read by the new code (matches this project's existing "cache files are never actively deleted" precedent).
- Band cutoffs are computed per-file from the file's actual sample rate (`sampleRate / samplesPerBucket` gives Hz/bin), never hardcoded to one sample rate.
- Band values are normalized against the single loudest instant (across all three bands, all buckets) in the file, landing in the same 0...1 range `WaveformView`'s existing `min(magnitude, 1)` clamp expects.
- Offline analysis only, same trigger points as before (`stopAudioRecording()`, `importAudio(from:toTrackAt:)`, and `TimelineView`'s per-render lazy backfill) — no live/real-time analysis.
- No automated tests for SwiftUI view code (`WaveformView.swift`) or `AppState`-extension file-I/O/async code (`AppState+Waveforms.swift`) — matches this project's established precedent. `WaveformBands` itself (pure logic in `AudioEngine`) is the one piece with unit tests.
- Meridian Studio-only — no change to Meridian Companion.

## Review Focus

- **Stereo (multi-channel) input.** Imported files are commonly stereo; the channel-averaging downmix must not crash or silently misbehave on a 2-channel buffer. → Task 1 adds a stereo-file test.
- **A file shorter than one full bucket (< 512 samples).** A very brief recording must still produce exactly one (zero-padded) bucket without a crash or NaN, not silently drop the region's waveform. → Task 1 adds a short-buffer test.
- **A silent (all-zero) file.** `overallMax` is 0, so the normalization divide must be guarded — a NaN here would render the whole waveform as garbage forever (the cache would never self-correct, no version field). → Task 1 adds a silent-file test.
- **A sample rate other than 44.1kHz** (48kHz is common for imports). Band cutoffs are computed from the file's real sample rate; a hardcoded-bin bug would only surface at a non-44.1kHz rate. → Task 1 adds a 48kHz-file test.
- **A project saved before this milestone, with an orphaned `.peaks` file and no `.bandpeaks` file.** The loader must regenerate fresh `.bandpeaks` data rather than attempting to read/reinterpret the old format. Not automated (matches the established no-test precedent for `AppState`-extension code) — covered by Task 2's manual smoke test instead.

---

### Task 1: `WaveformBands` (AudioEngine)

**Files:**
- Create: `Sources/AudioEngine/WaveformBands.swift`
- Create: `Tests/AudioEngineTests/WaveformBandsTests.swift`
- (`Sources/AudioEngine/WaveformPeaks.swift`/`Tests/AudioEngineTests/WaveformPeaksTests.swift` are left untouched here — this task is purely additive, so the build and test suite stay green with both types coexisting. Task 2 deletes them once every consumer has migrated.)

**Interfaces:**
- Consumes: nothing from `AudioLevelMeter` this time (see spec §2 — FFT needs real samples, not a pre-reduced peak scalar).
- Produces: `WaveformBands.samplesPerBucket: AVAudioFrameCount`, `WaveformBands.analyze(fileURL: URL) throws -> WaveformBands`, `WaveformBands(low: [Float], mid: [Float], high: [Float])`, `.low`/`.mid`/`.high: [Float]`, `.write(to: URL) throws`, `.read(from: URL) throws -> WaveformBands` (`static`). Used by Task 2's `AppState+Waveforms.swift`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AudioEngineTests/WaveformBandsTests.swift
import XCTest
import AVFoundation
@testable import AudioEngine

final class WaveformBandsTests: XCTestCase {
    /// Writes `frameCount` samples of a `frequency`Hz sine tone (amplitude
    /// 0.8) to a temp WAV file, identical on every channel.
    private func makeToneFile(
        frequency: Float,
        frameCount: Int,
        sampleRate: Double = 44100,
        channels: AVAudioChannelCount = 1
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            let sample = Float(sin(2 * Double.pi * Double(frequency) * Double(frame) / sampleRate)) * 0.8
            for channel in 0..<Int(channels) {
                buffer.floatChannelData![channel][frame] = sample
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testLowToneDominatesLowBand() throws {
        let url = try makeToneFile(frequency: 100, frameCount: Int(WaveformBands.samplesPerBucket))
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.low.count, 1)
        XCTAssertEqual(bands.low[0], 1.0, accuracy: 0.0001)
        XCTAssertLessThan(bands.mid[0], 0.4)
        XCTAssertLessThan(bands.high[0], 0.4)
    }

    func testMidToneDominatesMidBand() throws {
        let url = try makeToneFile(frequency: 1000, frameCount: Int(WaveformBands.samplesPerBucket))
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.mid[0], 1.0, accuracy: 0.0001)
        XCTAssertLessThan(bands.low[0], 0.4)
        XCTAssertLessThan(bands.high[0], 0.4)
    }

    func testHighToneDominatesHighBand() throws {
        let url = try makeToneFile(frequency: 8000, frameCount: Int(WaveformBands.samplesPerBucket))
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.high[0], 1.0, accuracy: 0.0001)
        XCTAssertLessThan(bands.low[0], 0.4)
        XCTAssertLessThan(bands.mid[0], 0.4)
    }

    func testStereoInputDoesNotCrashAndDownmixesConsistently() throws {
        let url = try makeToneFile(frequency: 1000, frameCount: Int(WaveformBands.samplesPerBucket), channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.mid.count, 1)
        XCTAssertEqual(bands.mid[0], 1.0, accuracy: 0.0001)
        XCTAssertLessThan(bands.low[0], 0.4)
        XCTAssertLessThan(bands.high[0], 0.4)
    }

    func testShorterThanOneBucketProducesOneZeroPaddedBucketNoCrash() throws {
        let url = try makeToneFile(frequency: 1000, frameCount: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.low.count, 1)
        XCTAssertEqual(bands.mid.count, 1)
        XCTAssertEqual(bands.high.count, 1)
        XCTAssertFalse(bands.low[0].isNaN)
        XCTAssertFalse(bands.mid[0].isNaN)
        XCTAssertFalse(bands.high[0].isNaN)
    }

    func testSilentFileProducesZeroBandsNoDivideByZero() throws {
        let url = try makeToneFile(frequency: 0, frameCount: Int(WaveformBands.samplesPerBucket))
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.low.count, 1)
        XCTAssertFalse(bands.low[0].isNaN)
        XCTAssertFalse(bands.mid[0].isNaN)
        XCTAssertFalse(bands.high[0].isNaN)
        XCTAssertEqual(bands.low[0], 0, accuracy: 0.0001)
        XCTAssertEqual(bands.mid[0], 0, accuracy: 0.0001)
        XCTAssertEqual(bands.high[0], 0, accuracy: 0.0001)
    }

    func testNonStandardSampleRateStillSeparatesBandsCorrectly() throws {
        let url = try makeToneFile(frequency: 8000, frameCount: Int(WaveformBands.samplesPerBucket), sampleRate: 48000)
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.high[0], 1.0, accuracy: 0.0001)
        XCTAssertLessThan(bands.low[0], 0.4)
        XCTAssertLessThan(bands.mid[0], 0.4)
    }

    func testWriteAndReadRoundTrip() throws {
        let bands = WaveformBands(low: [0, 0.25, 0.5], mid: [1.0, 0.75, 0.5], high: [0.1, 0.2, 0.3])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bandpeaks")
        defer { try? FileManager.default.removeItem(at: url) }

        try bands.write(to: url)
        let readBack = try WaveformBands.read(from: url)

        XCTAssertEqual(readBack.low, bands.low)
        XCTAssertEqual(readBack.mid, bands.mid)
        XCTAssertEqual(readBack.high, bands.high)
    }

    func testReadOfEmptyFileProducesEmptyBands() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bandpeaks")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.read(from: url)

        XCTAssertTrue(bands.low.isEmpty)
        XCTAssertTrue(bands.mid.isEmpty)
        XCTAssertTrue(bands.high.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WaveformBandsTests`
Expected: FAIL to build — "cannot find type 'WaveformBands' in scope".

- [ ] **Step 3: Implement `WaveformBands`**

```swift
// Sources/AudioEngine/WaveformBands.swift
import Accelerate
import AVFoundation

/// Three frequency-band energy magnitudes per fixed-size bucket of an
/// audio file, for rendering a multi-color waveform. Unlike the
/// waveform-rendering milestone's `WaveformPeaks`, this does not reuse
/// `AudioLevelMeter.peak(of:)` — splitting energy by frequency needs the
/// actual time-domain samples run through an FFT, not a pre-reduced
/// peak scalar. `AudioLevelMeter` itself is untouched; it still serves
/// the live level meter exactly as before.
public struct WaveformBands: Sendable {
    public static let samplesPerBucket: AVAudioFrameCount = 512

    /// <250Hz — kick/bass fundamentals.
    public let low: [Float]
    /// 250Hz–2kHz — vocals, guitars, most harmonic content.
    public let mid: [Float]
    /// >2kHz — cymbals, air, transient detail.
    public let high: [Float]

    public init(low: [Float], mid: [Float], high: [Float]) {
        self.low = low
        self.mid = mid
        self.high = high
    }

    public static func analyze(fileURL: URL) throws -> WaveformBands {
        let file = try AVAudioFile(forReading: fileURL)
        let sampleRate = Float(file.processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: samplesPerBucket) else {
            return WaveformBands(low: [], mid: [], high: [])
        }

        let n = Int(samplesPerBucket)
        let log2n = vDSP_Length(log2(Float(n)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return WaveformBands(low: [], mid: [], high: [])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Bin `i` (0..<n/2) covers frequency `i * sampleRate / n`.
        let binHz = sampleRate / Float(n)
        let lowCutoffBin = Int(250 / binHz)
        let midCutoffBin = Int(2000 / binHz)

        var low: [Float] = []
        var mid: [Float] = []
        var high: [Float] = []
        var overallMax: Float = 0

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: samplesPerBucket)
            guard buffer.frameLength > 0 else { break }
            let energies = bandEnergies(
                of: buffer, window: window, fftSetup: fftSetup, log2n: log2n,
                lowCutoffBin: lowCutoffBin, midCutoffBin: midCutoffBin
            )
            low.append(energies.0)
            mid.append(energies.1)
            high.append(energies.2)
            overallMax = max(overallMax, energies.0, energies.1, energies.2)
        }

        // Normalize all three bands against the single loudest instant in
        // the whole file, so the result lands in the same 0...1 range
        // `WaveformView` already clamps to. Raw FFT bin-energy sums have no
        // natural ceiling the way a sample's absolute value did, so this
        // introduces one explicitly. `overallMax == 0` (a silent file)
        // returns the all-zero arrays unnormalized rather than dividing by
        // zero.
        guard overallMax > 0 else { return WaveformBands(low: low, mid: mid, high: high) }
        return WaveformBands(
            low: low.map { $0 / overallMax },
            mid: mid.map { $0 / overallMax },
            high: high.map { $0 / overallMax }
        )
    }

    private static func bandEnergies(
        of buffer: AVAudioPCMBuffer, window: [Float], fftSetup: FFTSetup, log2n: vDSP_Length,
        lowCutoffBin: Int, midCutoffBin: Int
    ) -> (Float, Float, Float) {
        let n = Int(samplesPerBucket)
        let half = n / 2

        // Downmix to one signal by averaging channels — not the level
        // meter's "largest absolute value across channels" convention,
        // which only makes sense for a single reduced scalar. An FFT needs
        // one coherent time-domain signal to transform. `frameCount` may be
        // less than `n` for the file's last bucket; `samples` stays
        // zero-initialized past it, which is exactly the zero-padding this
        // milestone relies on for a short/final partial bucket.
        var samples = [Float](repeating: 0, count: n)
        if let channelData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameCount = Int(buffer.frameLength)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channelData[channel][frame] }
                samples[frame] = sum / Float(channelCount)
            }
        }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        func sumMagnitude(_ range: Range<Int>) -> Float {
            let clamped = range.clamped(to: 0..<half)
            guard !clamped.isEmpty else { return 0 }
            var sum: Float = 0
            vDSP_sve(Array(magnitudes[clamped]), 1, &sum, vDSP_Length(clamped.count))
            return sqrt(sum)
        }

        return (
            sumMagnitude(0..<lowCutoffBin),
            sumMagnitude(lowCutoffBin..<midCutoffBin),
            sumMagnitude(midCutoffBin..<half)
        )
    }

    /// Interleaved `Float32` triples (low, mid, high) per bucket — no
    /// header, no version field, same regenerable-cache convention as
    /// `WaveformPeaks`. Written at `.bandpeaks`, never `.peaks`: an old
    /// `.peaks` file (one float/bucket) would misparse under this
    /// three-floats/bucket layout with no way to detect the mismatch, so
    /// this uses a distinct extension rather than reinterpreting old cache
    /// files. Old `.peaks` files are simply orphaned — matches this
    /// project's existing "cache files are never actively deleted"
    /// precedent.
    public func write(to url: URL) throws {
        var interleaved: [Float] = []
        interleaved.reserveCapacity(low.count * 3)
        for i in 0..<low.count {
            interleaved.append(low[i])
            interleaved.append(mid[i])
            interleaved.append(high[i])
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> WaveformBands {
        let data = try Data(contentsOf: url)
        let floatCount = data.count / MemoryLayout<Float>.size
        let bucketCount = floatCount / 3
        var interleaved = [Float](repeating: 0, count: bucketCount * 3)
        _ = interleaved.withUnsafeMutableBytes {
            data.copyBytes(to: $0, count: bucketCount * 3 * MemoryLayout<Float>.size)
        }
        var low = [Float](repeating: 0, count: bucketCount)
        var mid = [Float](repeating: 0, count: bucketCount)
        var high = [Float](repeating: 0, count: bucketCount)
        for i in 0..<bucketCount {
            low[i] = interleaved[i * 3]
            mid[i] = interleaved[i * 3 + 1]
            high[i] = interleaved[i * 3 + 2]
        }
        return WaveformBands(low: low, mid: mid, high: high)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WaveformBandsTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests still pass alongside the 9 new ones. `WaveformPeaksTests` still exists and still passes too — Task 2 is the one that removes it.

- [ ] **Step 6: Commit**

```bash
git add Sources/AudioEngine/WaveformBands.swift Tests/AudioEngineTests/WaveformBandsTests.swift
git commit -m "Add FFT-based WaveformBands (low/mid/high per bucket), alongside WaveformPeaks"
```

---

### Task 2: Migrate AppState, WaveformView, and TimelineView to WaveformBands

This task is one atomic unit, not split further: `AppState`'s cache/loader API can't be renamed without breaking `TimelineView`'s only call site in the same instant, and patching that gap with a temporary second name would be exactly the kind of compatibility shim this project avoids. Every file below moves together, in one commit, and only then is the now-fully-unreferenced `WaveformPeaks` deleted.

**Files:**
- Modify: `Sources/MeridianStudioApp/AppState.swift:40-52`
- Modify: `Sources/MeridianStudioApp/AppState+Waveforms.swift` (full rewrite)
- Modify: `Sources/MeridianStudioApp/AppState+AudioRecording.swift:64`
- Modify: `Sources/MeridianStudioApp/AppState+AudioImport.swift:81`
- Modify: `Sources/MeridianStudioApp/WaveformView.swift` (full rewrite)
- Modify: `Sources/MeridianStudioApp/TimelineView.swift:51-55`
- Delete: `Sources/AudioEngine/WaveformPeaks.swift`, `Tests/AudioEngineTests/WaveformPeaksTests.swift`

**Interfaces:**
- Consumes: `WaveformBands.analyze(fileURL:)`/`.write(to:)`/`.read(from:)`/`.low`/`.mid`/`.high` (Task 1). `AppState.fileURL` (pre-existing).
- Produces: `AppState.waveformBands(for: AudioRegion) -> WaveformBands?` and `WaveformView(bands: WaveformBands)` — both defined and consumed within this same task, so there is no cross-task interface to keep in sync.

No automated tests for the `AppState`/view changes in this task — matches this project's established precedent for `AppState`-file-I/O-and-async-driven code and SwiftUI view code (see Global Constraints). Verified by build, the full test suite (regression only — confirms deleting `WaveformPeaksTests` didn't take anything else down with it), and this task's own manual smoke test.

- [ ] **Step 1: Rename the cache properties in `AppState.swift`**

In `Sources/MeridianStudioApp/AppState.swift`, find:

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
    /// Deliberately NOT `@Published`, unlike `waveformCache`: it's mutated
    /// from inside `TimelineView.body` during a SwiftUI render pass, and
    /// publishing from there would risk a re-render loop.
    var waveformLoadsInFlight: Set<String> = []
```

Replace with:

```swift
    /// Cached waveform bands for audio regions, keyed by
    /// `AudioRegion.fileName`. Populated by `waveformBands(for:)` in
    /// `AppState+Waveforms.swift`, off the main thread — `@Published` so
    /// `TimelineView` redraws once a load completes. Not `private`: both
    /// this file and `AppState+Waveforms.swift` read and write it.
    @Published var bandCache: [String: WaveformBands] = [:]
    /// Dedupes concurrent loads for the same file. Never cleared on
    /// failure — see `AppState+Waveforms.swift` for why that's
    /// intentional (at most one analysis attempt per file per session).
    /// Deliberately NOT `@Published`, unlike `bandCache`: it's mutated
    /// from inside `TimelineView.body` during a SwiftUI render pass, and
    /// publishing from there would risk a re-render loop.
    var bandLoadsInFlight: Set<String> = []
```

- [ ] **Step 2: Rewrite `AppState+Waveforms.swift`**

```swift
// Sources/MeridianStudioApp/AppState+Waveforms.swift
import AudioEngine
import Foundation
import ProjectModel

extension AppState {
    /// Returns cached bands for `region` if already loaded, and kicks off
    /// a background load (a cached `.bandpeaks` file, or a fresh FFT
    /// analysis) if not. Callers simply re-invoke on every render; the
    /// `@Published` cache write on completion triggers the redraw that
    /// shows the result. Also the single call site used to generate bands
    /// right after a recording or import finishes — same function,
    /// whether this is a brand-new region or an older one seen for the
    /// first time (including one from before this milestone, whose
    /// `.peaks` file this never reads).
    func waveformBands(for region: AudioRegion) -> WaveformBands? {
        if let cached = bandCache[region.fileName] { return cached }
        guard let fileURL, bandLoadsInFlight.insert(region.fileName).inserted else { return nil }
        let audioDirectory = fileURL.appendingPathComponent("audio")
        let audioFileURL = audioDirectory.appendingPathComponent(region.fileName)
        let bandsFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("bandpeaks")
        Task.detached(priority: .utility) {
            let bands = (try? WaveformBands.read(from: bandsFileURL)).flatMap { $0.low.isEmpty ? nil : $0 }
                ?? (try? WaveformBands.analyze(fileURL: audioFileURL))
            guard let bands else { return }
            try? bands.write(to: bandsFileURL)
            await MainActor.run { self.bandCache[region.fileName] = bands }
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
            _ = waveformPeaks(for: region)
        } catch {
            presentError(error)
        }
```

Replace with:

```swift
        do {
            try FileManager.default.moveItem(at: workingURL, to: finalURL)
            document.addAudioRegion(region, toTrackAt: selectedTrackIndex)
            _ = waveformBands(for: region)
        } catch {
            presentError(error)
        }
```

- [ ] **Step 4: Wire into `importAudio(from:toTrackAt:)`**

In `Sources/MeridianStudioApp/AppState+AudioImport.swift`, find:

```swift
        let region = AudioRegion(startBeat: startBeat, lengthBeats: max(lengthBeats, 0.1), fileName: destinationFileName)
        document.addAudioRegion(region, toTrackAt: trackIndex)
        _ = waveformPeaks(for: region)
```

Replace with:

```swift
        let region = AudioRegion(startBeat: startBeat, lengthBeats: max(lengthBeats, 0.1), fileName: destinationFileName)
        document.addAudioRegion(region, toTrackAt: trackIndex)
        _ = waveformBands(for: region)
```

- [ ] **Step 5: Rewrite `WaveformView.swift`**

```swift
// Sources/MeridianStudioApp/WaveformView.swift
import AudioEngine
import SwiftUI

/// Renders `bands` as three overlaid, translucent mirrored-bar traces —
/// low (bass), mid (vocals/harmony), high (cymbals/air) — stretched to
/// fill the view's width. Not a spectrogram: no vertical frequency axis,
/// just three pre-summed energy traces layered on the same timeline.
struct WaveformView: View {
    let bands: WaveformBands

    private static let lowColor = Color(red: 1.0, green: 0.37, blue: 0.34)
    private static let midColor = Color(red: 1.0, green: 0.85, blue: 0.24)
    private static let highColor = Color(red: 0.44, green: 0.89, blue: 1.0)

    var body: some View {
        Canvas { context, size in
            draw(bands.low, color: Self.lowColor, in: context, size: size)
            draw(bands.mid, color: Self.midColor, in: context, size: size)
            draw(bands.high, color: Self.highColor, in: context, size: size)
        }
    }

    private func draw(_ magnitudes: [Float], color: Color, in context: GraphicsContext, size: CGSize) {
        guard !magnitudes.isEmpty else { return }
        let midY = size.height / 2
        let barWidth = size.width / CGFloat(magnitudes.count)
        var path = Path()
        for (index, magnitude) in magnitudes.enumerated() {
            let x = CGFloat(index) * barWidth
            let barHeight = CGFloat(min(magnitude, 1)) * midY
            path.addRect(CGRect(x: x, y: midY - barHeight, width: max(barWidth, 0.5), height: barHeight * 2))
        }
        context.fill(path, with: .color(color.opacity(0.6)))
    }
}
```

- [ ] **Step 6: Update the call site in `TimelineView.swift`**

In `Sources/MeridianStudioApp/TimelineView.swift`, find:

```swift
                                .overlay {
                                    if let peaks = appState.waveformPeaks(for: region) {
                                        WaveformView(peaks: peaks)
                                    }
                                }
```

Replace with:

```swift
                                .overlay {
                                    if let bands = appState.waveformBands(for: region) {
                                        WaveformView(bands: bands)
                                    }
                                }
```

`.overlay`'s position in the modifier chain (before `.offset()`) is unchanged — only its contents change, so this cannot reintroduce the offset-ordering bug the audio-import milestone fixed.

- [ ] **Step 7: Delete the now-unreferenced `WaveformPeaks`**

Every consumer (`AppState`, `WaveformView`, `TimelineView`) has moved to `WaveformBands` as of the previous steps, so this is safe now — it wasn't safe in Task 1.

```bash
git rm Sources/AudioEngine/WaveformPeaks.swift Tests/AudioEngineTests/WaveformPeaksTests.swift
```

- [ ] **Step 8: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 9: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests (plus Task 1's 9 `WaveformBandsTests`) still pass; `WaveformPeaksTests` is gone, deleted in Step 7.

- [ ] **Step 10: Manual smoke test**

Check (in addition to everything from prior milestones' smoke-test checklists):

- Record a short audio take. Once it stops, the region shows three overlaid colors (red/bass, yellow/mid, cyan/high), not the old single off-white waveform.
- Import an existing `.wav` file. Same — three colors appear.
- Quit and reopen the project. The multi-band waveform for both regions reappears immediately (no visible delay/flicker), confirming it's reading the cached `.bandpeaks` file rather than recomputing.
- Open a project saved before this milestone (one with an existing `.peaks` file from the waveform-rendering milestone, and no `.bandpeaks` file yet). Confirm the region renders a fresh multi-band waveform shortly after appearing — the lazy-backfill path — and that a `.bandpeaks` file now exists next to the audio file, while the old `.peaks` file is left untouched (check its modification time doesn't change).
- Confirm an audio region with `startBeat > 0` still renders its waveform (and caption) at the correct offset position — regression check for the offset-ordering bug class this milestone is careful not to reintroduce.

- [ ] **Step 11: Commit**

```bash
git add Sources/MeridianStudioApp/AppState.swift Sources/MeridianStudioApp/AppState+Waveforms.swift Sources/MeridianStudioApp/AppState+AudioRecording.swift Sources/MeridianStudioApp/AppState+AudioImport.swift Sources/MeridianStudioApp/WaveformView.swift Sources/MeridianStudioApp/TimelineView.swift
git add Sources/AudioEngine/WaveformPeaks.swift Tests/AudioEngineTests/WaveformPeaksTests.swift
git commit -m "Migrate to WaveformBands: three-band colored waveforms end to end, retire WaveformPeaks"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** §1 (scope, including the explicit "not source separation" framing) → carried into the plan's Goal/Global Constraints, nothing added beyond it. §2 (band data & file format, including the log2n scoping bug caught and fixed during the spec's own self-review) → Task 1, verbatim, with `log2n` now correctly threaded as a parameter into `bandEnergies` rather than referenced out of scope. §3 (generation & caching) → Task 2, verbatim. §4 (rendering) → Task 2, verbatim. §5 (testing) → Task 1's 9 unit tests (3 tone-dominance tests plus the 4 Review Focus edge cases plus round-trip/empty-file) and Task 2's manual smoke test. §6 (non-goals) → nothing in any task exceeds them. No gaps found.
- **Placeholder scan:** no TBD/TODO; both tasks give complete, verbatim code and exact find/replace snippets.
- **Type consistency:** `WaveformBands.samplesPerBucket`/`.analyze(fileURL:)`/`.low`/`.mid`/`.high`/`.write(to:)`/`.read(from:)` (Task 1) are used with identical names and signatures in Task 2's loader and view. `AppState.waveformBands(for:) -> WaveformBands?` and `WaveformView(bands:)` (both Task 2) are each defined and consumed within that same task, so there's no cross-task interface drift to check. `bandCache`/`bandLoadsInFlight` (Task 2, Step 1) match the names Task 2's Step 2 loader reads/writes.
- **Task-boundary buildability:** caught during this self-review — an earlier draft deleted `WaveformPeaks` in Task 1 and split the `AppState` rename from the `TimelineView` call-site update across two task-commits, either of which would leave `swift build` broken mid-plan. Fixed by keeping Task 1 purely additive and merging the rename with its only call site into one atomic Task 2, deleting the old type only once nothing references it.
- **Review Focus:** all 5 items each map to a specific test or step — stereo (Task 1 `testStereoInputDoesNotCrashAndDownmixesConsistently`), short buffer (Task 1 `testShorterThanOneBucketProducesOneZeroPaddedBucketNoCrash`), silent file (Task 1 `testSilentFileProducesZeroBandsNoDivideByZero`), non-standard sample rate (Task 1 `testNonStandardSampleRateStillSeparatesBandsCorrectly`), stale `.peaks`/no `.bandpeaks` (Task 2's manual smoke test, 4th bullet).
