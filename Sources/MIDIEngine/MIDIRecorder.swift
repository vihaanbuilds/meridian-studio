import ProjectModel

public struct NoteRecorderClock {
    public var nowBeats: () -> Double

    public init(nowBeats: @escaping () -> Double) {
        self.nowBeats = nowBeats
    }
}

@MainActor
public final class MIDIRecorder {
    private var activeNotes: [UInt8: (velocity: UInt8, startBeat: Double)] = [:]
    public private(set) var recordedNotes: [NoteEvent] = []
    private let clock: NoteRecorderClock

    public init(clock: NoteRecorderClock) {
        self.clock = clock
    }

    public func handle(_ event: ParsedMIDIEvent) {
        switch event {
        case .noteOn(let pitch, let velocity, _):
            activeNotes[pitch] = (velocity, clock.nowBeats())
        case .noteOff(let pitch, _):
            guard let started = activeNotes.removeValue(forKey: pitch) else { return }
            let length = max(clock.nowBeats() - started.startBeat, 0.0)
            recordedNotes.append(
                NoteEvent(pitch: pitch, velocity: started.velocity, startBeat: started.startBeat, lengthBeats: length)
            )
        case .other:
            break
        }
    }

    public func reset() {
        activeNotes.removeAll()
        recordedNotes.removeAll()
    }
}
