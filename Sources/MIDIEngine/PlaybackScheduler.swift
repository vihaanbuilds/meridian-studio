// Sources/MIDIEngine/PlaybackScheduler.swift
import ProjectModel

public struct ScheduledNote: Equatable {
    public var pitch: UInt8
    public var velocity: UInt8
    public var startSeconds: Double
    public var lengthSeconds: Double

    public init(pitch: UInt8, velocity: UInt8, startSeconds: Double, lengthSeconds: Double) {
        self.pitch = pitch
        self.velocity = velocity
        self.startSeconds = startSeconds
        self.lengthSeconds = lengthSeconds
    }
}

public enum PlaybackScheduler {
    public static func schedule(region: MIDIRegion, tempo: Double) -> [ScheduledNote] {
        region.notes.map { note in
            ScheduledNote(
                pitch: note.pitch,
                velocity: note.velocity,
                startSeconds: Tempo.seconds(forBeats: note.startBeat, tempo: tempo),
                lengthSeconds: Tempo.seconds(forBeats: note.lengthBeats, tempo: tempo)
            )
        }
    }
}
