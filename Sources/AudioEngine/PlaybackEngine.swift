// Sources/AudioEngine/PlaybackEngine.swift
@preconcurrency import AVFoundation
import ProjectModel
import os

@MainActor
public final class PlaybackEngine {
    /// Shared with `AudioRecorder`, which needs the same running engine's
    /// `inputNode` for simultaneous record + play back. `AppState` constructs
    /// `AudioRecorder(engine: playbackEngine.engine)`, which is why this can't
    /// stay `private`.
    public let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let audioPlayerNode = AVAudioPlayerNode()
    /// Every in-flight `Task` spawned by `play(regions:audioRegions:tempo:)`.
    /// Without this, Stop could not reach the sleeping tasks and they kept
    /// firing note-on/note-off after the transport had supposedly stopped.
    private var scheduledTasks: [Task<Void, Never>] = []
    private let currentOutputLevel = OSAllocatedUnfairLock<Float>(initialState: 0)

    public init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.attach(audioPlayerNode)
        engine.connect(audioPlayerNode, to: engine.mainMixerNode, format: nil)
        // Capture the lock directly, not `self` — this closure runs on a
        // real-time audio thread, never the main thread. `PlaybackEngine` is
        // `@MainActor`, so touching *any* of its properties via `self` here
        // requires main-actor isolation the audio thread doesn't have; the
        // compiler doesn't catch this (the `@preconcurrency import
        // AVFoundation` above suppresses that diagnostic), so it only
        // surfaces as a runtime "data race detected" trap when the tap
        // actually fires. `OSAllocatedUnfairLock` is genuinely `Sendable`
        // on its own, so capturing it directly sidesteps the actor-isolation
        // check instead of working around it.
        let currentOutputLevel = currentOutputLevel
        audioPlayerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            currentOutputLevel.withLock { $0 = AudioLevelMeter.peak(of: buffer) }
        }
    }

    public var level: Float {
        currentOutputLevel.withLock { $0 }
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        stopAllNotes()
        engine.stop()
    }

    /// Wall-clock scheduling via `Task.sleep` for MIDI notes (not sample-accurate
    /// `AVAudioTime` scheduling — acceptable for Phase 1's "audible and roughly
    /// in sync" bar; see docs/midi.md). Audio regions DO use `AVAudioTime`
    /// scheduling via `scheduleFile`, since `AVAudioPlayerNode` wants it and it
    /// costs nothing extra here. `audioRegions` are plain `(url, startBeat)`
    /// pairs, not `AudioRegion` values — this module never resolves filenames
    /// into project-bundle paths, the app layer does that before calling.
    public func play(regions: [MIDIRegion], audioRegions: [(url: URL, startBeat: Double)], tempo: Double) {
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
        for audioRegion in audioRegions {
            guard let file = try? AVAudioFile(forReading: audioRegion.url) else { continue }
            let startSeconds = Tempo.seconds(forBeats: audioRegion.startBeat, tempo: tempo)
            let when = AVAudioTime(
                sampleTime: AVAudioFramePosition(max(startSeconds, 0) * file.processingFormat.sampleRate),
                atRate: file.processingFormat.sampleRate
            )
            audioPlayerNode.scheduleFile(file, at: when)
        }
        audioPlayerNode.play()
    }

    /// Cancels every scheduled note still in flight and silences anything currently
    /// sounding, MIDI or audio. Safe to call when nothing is playing.
    public func stopAllNotes() {
        for task in scheduledTasks {
            task.cancel()
        }
        scheduledTasks.removeAll()
        for pitch in UInt8(0)...UInt8(127) {
            sampler.stopNote(pitch, onChannel: 0)
        }
        audioPlayerNode.stop()
    }
}
