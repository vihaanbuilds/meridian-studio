# Multi-Band Waveform — Design

Date: 2026-09-29
Status: Approved
Phase: 3 (waveform-rendering follow-on)

## 1. Scope

The waveform-rendering milestone drew one combined waveform per
`AudioRegion`. This milestone replaces that single-color waveform with
three overlaid, colored bands — low/mid/high frequency energy per
bucket — so a musician can visually tell "there's bass here, vocals
there, cymbals there" in a mixed recording, without ever separating it
into actual playable stems.

This is deliberately **not** instrument source separation. No new
audio is produced, no stems are written to disk, and nothing here
attempts to identify "this is a piano" vs "this is a guitar" — only
"energy is concentrated in this frequency range at this moment." Real
source separation (a trained model producing separate playable stems)
is a future, currently-undesigned milestone.

Deliberately out of scope, same "smallest useful slice" discipline
every prior milestone in this project has used:

- Real instrument/source separation (see above) — the reason this
  feature exists at all, but explicitly the *next* milestone, not this
  one.
- Live/real-time band analysis during recording — computed offline,
  after a take is recorded or a file is imported, exactly like the
  waveform-rendering milestone. The live level meter shown while
  recording is unchanged.
- A spectrogram (full frequency-vs-time heatmap) — considered and
  rejected in favor of the multi-band waveform for this milestone; the
  FFT groundwork this milestone adds would make a spectrogram a
  smaller lift later, but building one is not part of this scope.
- User-configurable band boundaries, band colors, or per-band
  mute/solo/visibility toggles.
- Zoom-aware resolution, stereo/per-channel display, click-to-seek,
  trim/split/fade/normalize — same non-goals the waveform-rendering
  milestone already carried, still true here.
- Any change to Meridian Companion (Meridian Studio-only, per the
  two-app architecture spec — Companion has no per-region waveform
  view at all today).

## 2. Band Data & File Format

`WaveformPeaks` (`Sources/AudioEngine/WaveformPeaks.swift`) is
**replaced**, not extended alongside — nothing outside
`AppState+Waveforms.swift`, `WaveformView.swift`, and their tests
references it, so there is no dual-format burden to carry. Its
successor, `WaveformBands`, keeps the same bucket size (512
samples — roughly 86–94 buckets/second at typical 44.1/48kHz sample
rates, same resolution as before) but stores **three** magnitudes per
bucket instead of one, computed via FFT instead of a time-domain peak:

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

        // Normalize all three bands against the single loudest instant
        // in the whole file, so the result lands in the same 0...1 range
        // `WaveformView` already clamps to — matching the old
        // `WaveformPeaks`' convention where a sample's absolute value was
        // naturally already in 0...1. Raw FFT bin-energy sums have no such
        // natural ceiling, so this milestone introduces one explicitly.
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
        // which only makes sense for a single reduced scalar. An FFT
        // needs one coherent time-domain signal to transform.
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
    /// this uses a distinct extension rather than reinterpreting old
    /// cache files. Old `.peaks` files are simply orphaned — matches this
    /// project's existing "cache files are never actively deleted"
    /// precedent for the waveform-rendering milestone.
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

No `Package.swift` change: `Accelerate` is a system framework, linked
implicitly the same way `AVFoundation` already is elsewhere in
`AudioEngine` with no explicit dependency declaration.

**Bin math at 44.1kHz** (illustrative — the actual cutoffs are computed
per-file from the real sample rate, not hardcoded): 512 samples ≈
86.1Hz/bin, so <250Hz is bins 0–2, 250Hz–2kHz is bins 3–23, >2kHz is
bins 24–255. (The implementation rounds cutoffs up with `ceil` rather
than truncating, caught during Task 1's implementation when truncation
let a 100Hz tone's spectral leakage bleed into the mid band, and
truncation also degenerates to an empty low band entirely at high
sample rates like 192kHz — see `Sources/AudioEngine/WaveformBands.swift`
for the real cutoff calculation.) Deliberately coarse at the low end
(bass energy is concentrated in very few bins at this resolution) and
wide at the high end — matches how energy is actually distributed in
typical program material, not an attempt at scientific precision.

## 3. Generation & Caching

Same triggers, same lazy-backfill shape as the waveform-rendering
milestone — only the type and cache extension change:

```swift
// Sources/MeridianStudioApp/AppState+Waveforms.swift
import AudioEngine
import Foundation
import ProjectModel

extension AppState {
    /// Returns cached bands for `region` if already loaded, and kicks off
    /// a background load (a cached `.bandpeaks` file, or a fresh FFT
    /// analysis) if not. Same call sites as before: right after
    /// recording/import finishes, and from `TimelineView` on every
    /// render as the lazy backfill for regions from before this
    /// milestone (or from before the waveform-rendering milestone,
    /// whose `.peaks` files this never reads).
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

`AppState.swift`'s existing `waveformCache`/`waveformLoadsInFlight`
properties are renamed/retyped to `bandCache: [String: WaveformBands]`
and `bandLoadsInFlight: Set<String>`, same `@Published`/plain split as
before, same doc-comment rationale (dedupe concurrent loads, never
cleared on failure so a failing file gets at most one analysis attempt
per app session).

`stopAudioRecording()` (`AppState+AudioRecording.swift`) and
`importAudio(from:toTrackAt:)` (`AppState+AudioImport.swift`) keep
their existing call sites, just renamed: `_ = waveformBands(for:
region)`.

## 4. Rendering

`WaveformView` draws the same mirrored-bar shape as before, once per
band, layered:

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

`TimelineView`'s call site is renamed to match (`appState
.waveformBands(for: region)` / `WaveformView(bands: bands)`); the
`.overlay` position relative to `.offset()` is untouched — already
correct from the waveform-rendering milestone, nothing here risks
reintroducing that ordering bug since the overlay's *position* in the
modifier chain doesn't change, only what's inside it.

## 5. Testing

- Unit tests for `WaveformBands.analyze`/`write`/`read` in
  `AudioEngineTests` (`WaveformBandsTests.swift`, replacing
  `WaveformPeaksTests.swift`): synthetic WAV files built from pure sine
  tones — a ~100Hz tone asserting most energy lands in `low`, a
  ~1000Hz tone asserting `mid`, an ~8000Hz tone asserting `high` — plus
  a write/read round-trip test and an empty-file test, mirroring the
  existing test's structure.
- No test for the `Canvas` rendering or `AppState+Waveforms`'s loader —
  same established precedent as before.
- Manual smoke test, extending the waveform-rendering milestone's
  checklist:
  - Record or import audio; confirm the region shows three overlaid
    colors (not the old single off-white waveform).
  - Quit and reopen the project; confirm the multi-band waveform
    reappears immediately (reading the cached `.bandpeaks` file).
  - Open a project from before this milestone (with an existing
    `.peaks` file and no `.bandpeaks` file); confirm a fresh multi-band
    analysis runs and produces a `.bandpeaks` file, and that the old
    `.peaks` file is left alone, unread.
  - Confirm a region with `startBeat > 0` still renders at the correct
    offset (regression check, same as before).

## 6. Non-Goals

- Real instrument/source separation — the motivating future milestone,
  not this one.
- A spectrogram view.
- Live/real-time band analysis during recording.
- User-configurable band boundaries, colors, or per-band
  mute/solo/visibility.
- Zoom-aware resolution, stereo/per-channel display, click-to-seek,
  trim/split/fade/normalize.
- Any change to Meridian Companion.
