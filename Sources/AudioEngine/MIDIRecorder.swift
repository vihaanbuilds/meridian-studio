import ProjectModel

public struct NoteRecorderClock {
    public var nowBeats: () -> Double

    public init(nowBeats: @escaping () -> Double) {
        self.nowBeats = nowBeats
    }
}

@MainActor
public final class MIDIRecorder {
    /// A *stack* of pending note-ons per pitch, not a single entry: a keyboard can
    /// send a second `.noteOn` for a pitch that is already held (retrigger, or a
    /// sustained key re-struck) before the matching `.noteOff` arrives. Storing one
    /// entry per pitch silently dropped the earlier note; the stack keeps both and
    /// resolves `.noteOff` LIFO, which matches how a held-then-retriggered key
    /// actually releases.
    private var activeNotes: [UInt8: [(velocity: UInt8, startBeat: Double)]] = [:]
    public private(set) var recordedNotes: [NoteEvent] = []
    private let clock: NoteRecorderClock

    public init(clock: NoteRecorderClock) {
        self.clock = clock
    }

    public func handle(_ event: ParsedMIDIEvent) {
        switch event {
        case .noteOn(let pitch, let velocity, _):
            activeNotes[pitch, default: []].append((velocity, clock.nowBeats()))
        case .noteOff(let pitch, _):
            guard var pending = activeNotes[pitch], let started = pending.popLast() else { return }
            if pending.isEmpty {
                activeNotes.removeValue(forKey: pitch)
            } else {
                activeNotes[pitch] = pending
            }
            let length = max(clock.nowBeats() - started.startBeat, 0.0)
            recordedNotes.append(
                NoteEvent(pitch: pitch, velocity: started.velocity, startBeat: started.startBeat, lengthBeats: length)
            )
        case .other:
            break
        }
    }

    /// Closes out every note still held at `beat` (i.e. keys that were down when
    /// recording stopped) so they land in `recordedNotes` instead of being dropped.
    /// Ordering across pitches follows dictionary iteration and is not deterministic;
    /// these are all notes that ended at the same instant, so relative order carries
    /// no musical meaning.
    public func finalize(atBeat beat: Double) {
        for (pitch, pending) in activeNotes {
            for note in pending {
                let length = max(beat - note.startBeat, 0.0)
                recordedNotes.append(
                    NoteEvent(pitch: pitch, velocity: note.velocity, startBeat: note.startBeat, lengthBeats: length)
                )
            }
        }
        activeNotes.removeAll()
    }

    public func reset() {
        activeNotes.removeAll()
        recordedNotes.removeAll()
    }
}
