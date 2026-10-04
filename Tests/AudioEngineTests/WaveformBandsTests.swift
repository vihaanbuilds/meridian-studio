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

    /// Writes `segments` back-to-back into one continuous file — each one
    /// a clean tone at its own frequency/amplitude/length. `analyze` reads
    /// in fixed `samplesPerBucket`-frame chunks regardless of how the file
    /// was written, so N full-bucket-sized segments produce N buckets,
    /// letting a test exercise more than one bucket (and, with a shorter
    /// final segment, a trailing zero-padded one).
    private func makeMultiToneFile(
        segments: [(frequency: Float, amplitude: Float, frameCount: Int)],
        sampleRate: Double = 44100
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for segment in segments {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(segment.frameCount))!
            buffer.frameLength = AVAudioFrameCount(segment.frameCount)
            for frame in 0..<segment.frameCount {
                let sample = Float(sin(2 * Double.pi * Double(segment.frequency) * Double(frame) / sampleRate)) * segment.amplitude
                buffer.floatChannelData![0][frame] = sample
            }
            try file.write(from: buffer)
        }
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

    /// Uses identical content on both channels, so this only exercises the
    /// no-crash/consistent-with-mono path, not true out-of-phase channel
    /// cancellation (e.g. hard-panned or anti-phase stereo content), which
    /// would partially cancel under the averaging downmix.
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

    func testMultipleBucketsAreAnalyzedInOrderAndNormalizedAcrossTheWholeFile() throws {
        let bucket = Int(WaveformBands.samplesPerBucket)
        // Strictly decreasing amplitudes (0.8 / 0.4 / 0.2) so bucket 0 is
        // unambiguously the loudest instant in the file regardless of
        // minor per-frequency FFT variance, directly exercising the "one
        // shared normalizer across every bucket in the file" rule — with
        // only one bucket (every other test here), that rule is trivially
        // satisfied and untested.
        let url = try makeMultiToneFile(segments: [
            (frequency: 100, amplitude: 0.8, frameCount: bucket),
            (frequency: 1000, amplitude: 0.4, frameCount: bucket),
            (frequency: 8000, amplitude: 0.2, frameCount: 200)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let bands = try WaveformBands.analyze(fileURL: url)

        XCTAssertEqual(bands.low.count, 3)
        XCTAssertEqual(bands.mid.count, 3)
        XCTAssertEqual(bands.high.count, 3)

        // Bucket 0: full-amplitude 100Hz is the file's loudest instant.
        XCTAssertGreaterThan(bands.low[0], bands.mid[0])
        XCTAssertGreaterThan(bands.low[0], bands.high[0])
        XCTAssertEqual(bands.low[0], 1.0, accuracy: 0.0001)

        // Bucket 1: 1000Hz dominates mid, at roughly half bucket 0's peak
        // (amplitude 0.4 vs. 0.8) — this is the normalization check.
        XCTAssertGreaterThan(bands.mid[1], bands.low[1])
        XCTAssertGreaterThan(bands.mid[1], bands.high[1])
        XCTAssertEqual(bands.mid[1], 0.5, accuracy: 0.05)

        // Bucket 2: a short, zero-padded 8kHz tail still reads as
        // high-dominant despite the truncation.
        XCTAssertGreaterThan(bands.high[2], bands.low[2])
        XCTAssertGreaterThan(bands.high[2], bands.mid[2])
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

        let sliced = bands.slice(fromSeconds: 0.005, toSeconds: 0.005, sampleRate: 44100)

        XCTAssertTrue(sliced.low.isEmpty)
        XCTAssertTrue(sliced.mid.isEmpty)
        XCTAssertTrue(sliced.high.isEmpty)
    }
}
