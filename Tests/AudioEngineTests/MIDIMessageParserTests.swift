// Tests/AudioEngineTests/MIDIMessageParserTests.swift
import XCTest
@testable import AudioEngine

final class MIDIMessageParserTests: XCTestCase {
    func testNoteOnParses() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0x90, data1: 60, data2: 100, timestamp: 5))
        XCTAssertEqual(event, .noteOn(pitch: 60, velocity: 100, timestamp: 5))
    }

    func testNoteOnWithZeroVelocityIsNoteOff() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0x90, data1: 60, data2: 0, timestamp: 5))
        XCTAssertEqual(event, .noteOff(pitch: 60, timestamp: 5))
    }

    func testNoteOffParses() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0x80, data1: 60, data2: 64, timestamp: 5))
        XCTAssertEqual(event, .noteOff(pitch: 60, timestamp: 5))
    }

    func testControlChangeIsOther() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0xB0, data1: 7, data2: 127, timestamp: 5))
        XCTAssertEqual(event, .other)
    }
}
