// Tests/AudioEngineTests/MIDIRecorderTests.swift
import XCTest
import ProjectModel
@testable import AudioEngine

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

    func testRetriggeredSamePitchDoesNotLoseTheFirstNote() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 0.5
        recorder.handle(.noteOn(pitch: 60, velocity: 80, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        time = 1.5
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))

        // LIFO: the first note-off closes the most recent (retriggered) note-on.
        XCTAssertEqual(recorder.recordedNotes, [
            NoteEvent(pitch: 60, velocity: 80, startBeat: 0.5, lengthBeats: 0.5),
            NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1.5)
        ])
    }

    func testFinalizeClosesOutStillHeldNote() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        // The take ran on for two beats and the key was never released, so there is
        // no note-off to pair with. `AppState.stopRecording()` passes the clock's
        // final beat position the same way.
        time = 2.0
        recorder.finalize(atBeat: time)

        XCTAssertEqual(recorder.recordedNotes, [
            NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2)
        ])
    }

    func testFinalizeClosesEveryHeldNoteAndClearsPendingState() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 0.5
        recorder.handle(.noteOn(pitch: 64, velocity: 90, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOn(pitch: 60, velocity: 70, timestamp: 0))

        recorder.finalize(atBeat: 3.0)

        // Cross-pitch ordering follows dictionary iteration, so assert membership
        // (NoteEvent is Equatable but not Hashable, so no Set comparison here).
        XCTAssertEqual(recorder.recordedNotes.count, 3)
        XCTAssertTrue(recorder.recordedNotes.contains(
            NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 3)
        ))
        XCTAssertTrue(recorder.recordedNotes.contains(
            NoteEvent(pitch: 64, velocity: 90, startBeat: 0.5, lengthBeats: 2.5)
        ))
        XCTAssertTrue(recorder.recordedNotes.contains(
            NoteEvent(pitch: 60, velocity: 70, startBeat: 1.0, lengthBeats: 2.0)
        ))

        // Finalize consumed the pending state: a second finalize adds nothing,
        // and a stray later note-off has nothing left to pair with.
        recorder.finalize(atBeat: 4.0)
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        XCTAssertEqual(recorder.recordedNotes.count, 3)
    }
}
