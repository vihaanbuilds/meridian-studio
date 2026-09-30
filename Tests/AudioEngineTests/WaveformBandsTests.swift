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
