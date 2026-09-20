import XCTest
@testable import AudioEngine

final class MIDIEventQueueTests: XCTestCase {
    func testPushAndDrainPreservesOrder() {
        let queue = MIDIEventQueue(capacity: 4)
        let messages = (0..<3).map { RawMIDIMessage(status: 0x90, data1: UInt8($0), data2: 100, timestamp: 0) }
        messages.forEach { queue.push($0) }
        XCTAssertEqual(queue.drain(), messages)
    }

    func testDropsMessagesWhenFull() {
        let queue = MIDIEventQueue(capacity: 2)
        queue.push(RawMIDIMessage(status: 0x90, data1: 1, data2: 100, timestamp: 0))
        queue.push(RawMIDIMessage(status: 0x90, data1: 2, data2: 100, timestamp: 0))
        queue.push(RawMIDIMessage(status: 0x90, data1: 3, data2: 100, timestamp: 0)) // dropped, queue is full

        let drained = queue.drain()
        XCTAssertEqual(drained.map(\.data1), [1, 2])
    }

    func testDrainEmptiesQueue() {
        let queue = MIDIEventQueue()
        queue.push(RawMIDIMessage(status: 0x90, data1: 1, data2: 100, timestamp: 0))
        _ = queue.drain()
        XCTAssertEqual(queue.drain(), [])
    }
}
