import AVFoundation

/// A simple peak meter (largest absolute sample value across every channel and
/// frame), not RMS/dB. Pure and hardware-free, so it's the one piece of audio
/// level metering testable without a real input/output device — matches this
/// project's existing split between pure logic (`MIDIMessageParser`,
/// `PlaybackScheduler`) and their hardware-adjacent, untested siblings
/// (`CoreMIDIInput`, `PlaybackEngine`).
public enum AudioLevelMeter {
    public static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                peak = max(peak, abs(samples[frame]))
            }
        }
        return peak
    }
}
