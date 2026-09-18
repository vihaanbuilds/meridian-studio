import XCTest
@testable import ProjectModel

final class TrackAudibilityTests: XCTestCase {
    func testNoSoloReturnsAllUnmutedTracks() {
        let tracks = [
            Track(name: "Piano"),
            Track(name: "Bass", muted: true),
            Track(name: "Drums")
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Piano", "Drums"])
    }

    func testOneSoloedTrackReturnsOnlyIt() {
        let tracks = [
            Track(name: "Piano"),
            Track(name: "Bass", solo: true),
            Track(name: "Drums")
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Bass"])
    }

    func testMultipleSoloedTracksReturnAllOfThem() {
        let tracks = [
            Track(name: "Piano", solo: true),
            Track(name: "Bass"),
            Track(name: "Drums", solo: true)
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Piano", "Drums"])
    }

    func testSoloOverridesMuteOnTheSameTrack() {
        let tracks = [
            Track(name: "Piano", muted: true, solo: true),
            Track(name: "Bass")
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Piano"])
    }
}
