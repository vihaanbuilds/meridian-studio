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
        let lowCutoffBin = Int(ceil(250 / binHz))
        let midCutoffBin = Int(ceil(2000 / binHz))

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
