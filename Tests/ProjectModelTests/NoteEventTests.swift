import XCTest
@testable import ProjectModel

final class NoteEventTests: XCTestCase {
    func testEqualityIgnoresID() {
        let a = NoteEvent(id: UUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let b = NoteEvent(id: UUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a, b)
    }

    func testDecodingWithoutIDSynthesizesOne() throws {
        let json = """
        {"pitch": 60, "velocity": 100, "startBeat": 0, "lengthBeats": 1}
        """
        let note = try JSONDecoder().decode(NoteEvent.self, from: Data(json.utf8))
        XCTAssertEqual(note.pitch, 60)
    }

    func testDecodingWithIDRoundTripsThatID() throws {
        let originalID = UUID()
        let json = """
        {"id": "\(originalID.uuidString)", "pitch": 60, "velocity": 100, "startBeat": 0, "lengthBeats": 1}
        """
        let note = try JSONDecoder().decode(NoteEvent.self, from: Data(json.utf8))
        XCTAssertEqual(note.id, originalID)
    }

    func testEncodeDecodeRoundTripsID() throws {
        let original = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 2)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteEvent.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
    }
}
