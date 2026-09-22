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
