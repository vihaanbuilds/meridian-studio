// Sources/AudioEngine/AudioRecorder.swift
import AVFoundation
import os

/// Captures the shared `AVAudioEngine`'s microphone input to a file. Writing to
/// disk and computing a peak level directly inside the tap callback is the
/// simplest professional implementation — not the glitch-proof
/// ring-buffer-plus-writer-thread design a professional multitrack DAW
/// eventually needs under heavy system load, but the standard, widely-used
/// pattern for straightforward single-track recording (see docs/audio.md).
public final class AudioRecorder {
    private let engine: AVAudioEngine
    private var audioFile: AVAudioFile?
    private let currentLevel = OSAllocatedUnfairLock<Float>(initialState: 0)

    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    public func start(to url: URL) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        audioFile = file
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            try? file.write(from: buffer)
            self.currentLevel.withLock { $0 = AudioLevelMeter.peak(of: buffer) }
        }
    }

    /// Returns the URL just recorded to, or `nil` if nothing was in progress.
    /// Safe to call even if `start` was never called.
    public func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        let url = audioFile?.url
        audioFile = nil
        currentLevel.withLock { $0 = 0 }
        return url
    }

    public var level: Float {
        currentLevel.withLock { $0 }
    }
}
