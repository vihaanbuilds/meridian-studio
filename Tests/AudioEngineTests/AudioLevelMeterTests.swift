import XCTest
import AVFoundation
@testable import AudioEngine

final class AudioLevelMeterTests: XCTestCase {
    private func makeBuffer(channels samples: [[Float]]) -> AVAudioPCMBuffer {
        let channelCount = UInt32(samples.count)
        let frameCount = samples.first?.count ?? 0
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: channelCount)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<samples.count {
            for frame in 0..<samples[channel].count {
                buffer.floatChannelData![channel][frame] = samples[channel][frame]
            }
        }
        return buffer
    }

    func testSilenceHasZeroPeak() {
        let buffer = makeBuffer(channels: [[0, 0, 0, 0]])
        XCTAssertEqual(AudioLevelMeter.peak(of: buffer), 0, accuracy: 0.0001)
    }

    func testPeakIsTheLargestAbsoluteSampleValue() {
        let buffer = makeBuffer(channels: [[0.1, -0.5, 0.3, -0.2]])
        XCTAssertEqual(AudioLevelMeter.peak(of: buffer), 0.5, accuracy: 0.0001)
    }

    func testPeakIsTheMaximumAcrossChannels() {
        let buffer = makeBuffer(channels: [[0.1, 0.2], [0.6, 0.05]])
        XCTAssertEqual(AudioLevelMeter.peak(of: buffer), 0.6, accuracy: 0.0001)
    }
}
