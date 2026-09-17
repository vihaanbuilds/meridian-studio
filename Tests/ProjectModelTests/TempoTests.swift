import XCTest
@testable import ProjectModel

final class TempoTests: XCTestCase {
    func testSecondsAt120BPM() {
        XCTAssertEqual(Tempo.seconds(forBeats: 1, tempo: 120), 0.5, accuracy: 0.0001)
    }

    func testSecondsAt60BPM() {
        XCTAssertEqual(Tempo.seconds(forBeats: 4, tempo: 60), 4.0, accuracy: 0.0001)
    }

    func testBeatsAt120BPM() {
        XCTAssertEqual(Tempo.beats(forSeconds: 1, tempo: 120), 2.0, accuracy: 0.0001)
    }

    func testRoundTripIsIdentity() {
        let seconds = Tempo.seconds(forBeats: 3.5, tempo: 97)
        XCTAssertEqual(Tempo.beats(forSeconds: seconds, tempo: 97), 3.5, accuracy: 0.0001)
    }
}
