// Sources/MIDIEngine/PlaybackEngine.swift
import AVFoundation
import ProjectModel

@MainActor
public final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()

    public init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    /// Wall-clock scheduling via `Task.sleep`, not sample-accurate `AVAudioTime`
    /// scheduling — acceptable for Phase 1's "audible and roughly in sync" bar.
    /// See docs/midi.md for the sample-accurate-scheduling follow-up note.
    public func play(region: MIDIRegion, tempo: Double) {
        for scheduled in PlaybackScheduler.schedule(region: region, tempo: tempo) {
            Task { @MainActor [sampler] in
                try? await Task.sleep(nanoseconds: UInt64(max(scheduled.startSeconds, 0) * 1_000_000_000))
                sampler.startNote(scheduled.pitch, withVelocity: scheduled.velocity, onChannel: 0)
                try? await Task.sleep(nanoseconds: UInt64(max(scheduled.lengthSeconds, 0) * 1_000_000_000))
                sampler.stopNote(scheduled.pitch, onChannel: 0)
            }
        }
    }
}
