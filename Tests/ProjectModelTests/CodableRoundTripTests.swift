import XCTest
@testable import ProjectModel

final class CodableRoundTripTests: XCTestCase {
    func testNoteEventRoundTrips() throws {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(NoteEvent.self, from: data)
        XCTAssertEqual(decoded, note)
    }

    func testProjectRoundTrips() throws {
        let note = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 2)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let track = Track(name: "Piano", regions: [region])
        let project = Project(tracks: [track])

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.schemaVersion, Project.currentSchemaVersion)
    }
}
