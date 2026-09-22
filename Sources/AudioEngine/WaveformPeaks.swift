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
            do {
                try file.read(into: buffer, frameCount: samplesPerBucket)
            } catch {
                // AVAudioFile.read(into:frameCount:) throws an error when reading past EOF
                // instead of returning with frameLength = 0. Treat this as normal EOF.
                break
            }
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
