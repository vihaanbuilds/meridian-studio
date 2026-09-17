// Tests/MIDIEngineTests/MIDIRecorderTests.swift
import XCTest
import ProjectModel
@testable import MIDIEngine

@MainActor
final class MIDIRecorderTests: XCTestCase {
    func testRecordsSingleNote() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))

        XCTAssertEqual(recorder.recordedNotes, [NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)])
    }

    func testRecordsOverlappingNotesOnDifferentPitches() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 0.5
        recorder.handle(.noteOn(pitch: 64, velocity: 90, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        time = 1.5
        recorder.handle(.noteOff(pitch: 64, timestamp: 0))

        XCTAssertEqual(recorder.recordedNotes, [
            NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            NoteEvent(pitch: 64, velocity: 90, startBeat: 0.5, lengthBeats: 1)
        ])
    }

    func testNoteOffWithoutMatchingNoteOnIsIgnored() {
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { 0 }))
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        XCTAssertEqual(recorder.recordedNotes, [])
    }

    func testResetClearsState() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))
        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        recorder.reset()
        XCTAssertEqual(recorder.recordedNotes, [])
    }
}
