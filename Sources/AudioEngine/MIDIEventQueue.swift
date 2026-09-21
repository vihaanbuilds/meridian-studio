import os

/// Thread-safe handoff from the CoreMIDI callback thread to the main actor.
/// Allocation-free after construction; drops the newest message rather than
/// blocking or growing when full, per the real-time-safety principle.
public final class MIDIEventQueue: Sendable {
    private struct State {
        var buffer: [RawMIDIMessage?]
        var head = 0
        var tail = 0
        var count = 0
    }

    private let storage: OSAllocatedUnfairLock<State>

    public init(capacity: Int = 256) {
        storage = OSAllocatedUnfairLock(initialState: State(buffer: Array(repeating: nil, count: capacity)))
    }

    public func push(_ message: RawMIDIMessage) {
        storage.withLock { state in
            guard state.count < state.buffer.count else { return }
            state.buffer[state.tail] = message
            state.tail = (state.tail + 1) % state.buffer.count
            state.count += 1
        }
    }

    public func drain() -> [RawMIDIMessage] {
        storage.withLock { state in
            var result: [RawMIDIMessage] = []
            result.reserveCapacity(state.count)
            while state.count > 0 {
                if let message = state.buffer[state.head] {
                    result.append(message)
                }
                state.buffer[state.head] = nil
                state.head = (state.head + 1) % state.buffer.count
                state.count -= 1
            }
            return result
        }
    }
}
