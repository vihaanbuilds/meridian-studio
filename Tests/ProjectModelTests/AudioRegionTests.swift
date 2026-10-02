import XCTest
@testable import ProjectModel

final class AudioRegionTests: XCTestCase {
    func testEncodeDecodeRoundTrips() throws {
        let original = AudioRegion(startBeat: 2, lengthBeats: 4, fileName: "abc.wav")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioRegion.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSourceOffsetSecondsDefaultsToZero() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        XCTAssertEqual(region.sourceOffsetSeconds, 0)
    }

    func testEncodeDecodeRoundTripsWithNonZeroSourceOffset() throws {
        let original = AudioRegion(startBeat: 2, lengthBeats: 4, fileName: "abc.wav", sourceOffsetSeconds: 1.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioRegion.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.sourceOffsetSeconds, 1.5)
    }

    func testDecodesLegacyJSONMissingSourceOffsetSecondsAsZero() throws {
        let json = """
        {"id": "11111111-1111-1111-1111-111111111111", "startBeat": 0, "lengthBeats": 4, "fileName": "take1.wav"}
        """
        let region = try JSONDecoder().decode(AudioRegion.self, from: Data(json.utf8))
        XCTAssertEqual(region.sourceOffsetSeconds, 0)
        XCTAssertEqual(region.fileName, "take1.wav")
    }

    func testTrackKindAudioRoundTrips() throws {
        let data = try JSONEncoder().encode(TrackKind.audio)
        let decoded = try JSONDecoder().decode(TrackKind.self, from: data)
        XCTAssertEqual(decoded, .audio)
    }

    func testTrackDefaultsAudioRegionsToEmpty() {
        let track = Track(name: "Piano")
        XCTAssertTrue(track.audioRegions.isEmpty)
    }

    func testTrackDecodesLegacyJSONMissingAudioRegionsAsEmpty() throws {
        let json = """
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Piano", "kind": "midi", "muted": false, "solo": false, "regions": []}
        """
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        XCTAssertTrue(track.audioRegions.isEmpty)
        XCTAssertEqual(track.name, "Piano")
    }

    func testTrackEncodeDecodeRoundTripsAudioRegions() throws {
        let region = AudioRegion(startBeat: 0, lengthBeats: 2, fileName: "take1.wav")
        let original = Track(name: "Vocals", kind: .audio, audioRegions: [region])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
