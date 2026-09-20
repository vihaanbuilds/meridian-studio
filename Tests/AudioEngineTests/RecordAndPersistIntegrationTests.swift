// Tests/AudioEngineTests/RecordAndPersistIntegrationTests.swift
import XCTest
import ProjectModel
@testable import AudioEngine

@MainActor
final class RecordAndPersistIntegrationTests: XCTestCase {
    func testRecordSaveReopenRoundTrip() throws {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))

        recorder.handle(.noteOn(pitch: 64, velocity: 90, timestamp: 0))
        time = 2.0
        recorder.handle(.noteOff(pitch: 64, timestamp: 0))

        let region = MIDIRegion(startBeat: 0, lengthBeats: 2, notes: recorder.recordedNotes)
        let document = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        document.addRegion(region, toTrackAt: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("RoundTrip.mstudio")
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(document.project, to: url)
        let reopened = try ProjectStore.load(from: url)

        XCTAssertEqual(reopened, document.project)
        XCTAssertEqual(reopened.tracks[0].regions[0].notes.count, 2)
        XCTAssertEqual(reopened.tracks[0].regions[0].notes[0], NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1))
        XCTAssertEqual(reopened.tracks[0].regions[0].notes[1], NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1))
    }
}
