// Sources/AudioEngine/PlaybackEngine.swift
import AVFoundation
import ProjectModel

@MainActor
public final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    /// Every in-flight `Task` spawned by `play(regions:tempo:)`. Without this, Stop
    /// could not reach the sleeping tasks and they kept firing note-on/note-off
    /// after the transport had supposedly stopped.
    private var scheduledTasks: [Task<Void, Never>] = []

    public init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        stopAllNotes()
        engine.stop()
    }

    /// Wall-clock scheduling via `Task.sleep`, not sample-accurate `AVAudioTime`
    /// scheduling — acceptable for Phase 1's "audible and roughly in sync" bar.
    /// See docs/midi.md for the sample-accurate-scheduling follow-up note.
    public func play(regions: [MIDIRegion], tempo: Double) {
        // A second Play press must not stack on top of an unstopped previous one.
        // Called once here, not once per region — calling it per region would
        // cancel the previous region's just-scheduled tasks before they run.
        stopAllNotes()
        for region in regions {
            for scheduled in PlaybackScheduler.schedule(region: region, tempo: tempo) {
                let task = Task { @MainActor [sampler] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(scheduled.startSeconds, 0) * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        sampler.startNote(scheduled.pitch, withVelocity: scheduled.velocity, onChannel: 0)
                        try await Task.sleep(nanoseconds: UInt64(max(scheduled.lengthSeconds, 0) * 1_000_000_000))
                    } catch {
                        // Cancelled. `stopAllNotes()` is the only canceller and it has
                        // already sent note-off for every pitch, so this task must not
                        // send its own trailing note-off — a late one could silence a
                        // note the *next* play() just started on the same pitch.
                        return
                    }
                    sampler.stopNote(scheduled.pitch, onChannel: 0)
                }
                scheduledTasks.append(task)
            }
        }
    }

    /// Cancels every scheduled note still in flight and silences anything currently
    /// sounding. Safe to call when nothing is playing.
    public func stopAllNotes() {
        for task in scheduledTasks {
            task.cancel()
        }
        scheduledTasks.removeAll()
        for pitch in UInt8(0)...UInt8(127) {
            sampler.stopNote(pitch, onChannel: 0)
        }
    }
}
