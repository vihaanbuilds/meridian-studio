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
        Self.installLevelTap(on: audioPlayerNode, level: currentOutputLevel)
    }

    public var level: Float {
        currentOutputLevel.withLock { $0 }
    }

    /// Installs the tap outside `init()`'s `@MainActor` isolation on purpose.
    /// A closure formed lexically inside a `@MainActor` method inherits that
    /// isolation by default — regardless of whether its body ever touches
    /// `self` — and the compiler doesn't flag the mismatch (the
    /// `@preconcurrency import AVFoundation` above suppresses that
    /// diagnostic). But the tap callback always runs on a real-time audio
    /// thread, never the main thread, so a `@MainActor`-inferred closure
    /// traps at runtime ("data race detected") the moment it actually fires
    /// — which nothing in this project exercised until real hardware ran it.
    /// A `nonisolated` function breaks the inheritance chain: a closure
    /// formed inside one does not pick up the caller's actor isolation.
    /// `node`/`level` are passed as plain parameters rather than read via
    /// `self` so this method has no dependency on `self` at all.
    nonisolated private static func installLevelTap(on node: AVAudioPlayerNode, level: OSAllocatedUnfairLock<Float>) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            level.withLock { $0 = AudioLevelMeter.peak(of: buffer) }
        }
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
    /// scheduling via `scheduleSegment`, since `AVAudioPlayerNode` wants it and
    /// it costs nothing extra here. `audioRegions` are plain
    /// `(url, startBeat, sourceOffsetSeconds, lengthBeats)` tuples, not
    /// `AudioRegion` values — this module never resolves filenames into
    /// project-bundle paths, the app layer does that before calling.
    public func play(regions: [MIDIRegion], audioRegions: [(url: URL, startBeat: Double, sourceOffsetSeconds: Double, lengthBeats: Double)], tempo: Double) {
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
            let sampleRate = file.processingFormat.sampleRate
            let startSeconds = Tempo.seconds(forBeats: audioRegion.startBeat, tempo: tempo)
            let when = AVAudioTime(
                sampleTime: AVAudioFramePosition(max(startSeconds, 0) * sampleRate),
                atRate: sampleRate
            )
            // A hand-edited project file could carry a negative
            // `sourceOffsetSeconds`; clamp so a negative `startingFrame` never
            // reaches `scheduleSegment`.
            let startFrame = max(0, AVAudioFramePosition(audioRegion.sourceOffsetSeconds * sampleRate))
            let durationSeconds = Tempo.seconds(forBeats: audioRegion.lengthBeats, tempo: tempo)
            let requestedFrames = AVAudioFrameCount(max(durationSeconds, 0) * sampleRate)
            // Clamp to what's actually left in the file. For an untrimmed region
            // this should already match `requestedFrames` exactly (modulo
            // floating-point rounding in the beats<->seconds<->frames round trip);
            // this guard exists for a corrupt/truncated file, not to silently
            // paper over a real trim-bounds bug — Task 6's trim-handle clamp is
            // what actually keeps `requestedFrames` in range during normal use.
            let remainingFrames = AVAudioFrameCount(max(file.length - startFrame, 0))
            let frameCount = min(requestedFrames, remainingFrames)
            guard frameCount > 0 else { continue }
            audioPlayerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: when)
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
