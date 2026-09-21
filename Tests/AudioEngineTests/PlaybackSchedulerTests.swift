// Tests/AudioEngineTests/PlaybackSchedulerTests.swift
import XCTest
import ProjectModel
@testable import AudioEngine

final class PlaybackSchedulerTests: XCTestCase {
    func testSchedulesNotesAt120BPM() {
        let region = MIDIRegion(startBeat: 0, lengthBeats: 2, notes: [
            NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 0.5)
        ])

        let scheduled = PlaybackScheduler.schedule(region: region, tempo: 120)

        XCTAssertEqual(scheduled, [
            ScheduledNote(pitch: 60, velocity: 100, startSeconds: 0, lengthSeconds: 0.5),
            ScheduledNote(pitch: 64, velocity: 90, startSeconds: 0.5, lengthSeconds: 0.25)
        ])
    }
}
