import XCTest
@testable import ProjectModel

final class QuantizerTests: XCTestCase {
    func testZeroStrengthLeavesNotesUnchanged() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 0)
        XCTAssertEqual(result[0].startBeat, 0.3, accuracy: 0.0001)
    }

    func testFullStrengthSnapsToNearestGridLineBelow() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.30, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].startBeat, 0.25, accuracy: 0.0001)
    }

    func testFullStrengthSnapsToNearestGridLineAbove() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.45, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].startBeat, 0.5, accuracy: 0.0001)
    }

    func testNoteAlreadyOnGridIsUnchangedAtFullStrength() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.5, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].startBeat, 0.5, accuracy: 0.0001)
    }

    func testHalfStrengthMovesHalfwayToGrid() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.30, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 0.5)
        // Nearest grid line to 0.30 at 0.25 spacing is 0.25; halfway from 0.30 is 0.275.
        XCTAssertEqual(result[0].startBeat, 0.275, accuracy: 0.0001)
    }

    func testDifferentGridResolutionsProduceDifferentAnswers() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.6, lengthBeats: 1)
        let quarterGrid = Quantizer.quantize([note], gridBeats: 1.0, strength: 1)
        let eighthGrid = Quantizer.quantize([note], gridBeats: 0.5, strength: 1)
        XCTAssertEqual(quarterGrid[0].startBeat, 1.0, accuracy: 0.0001)
        XCTAssertEqual(eighthGrid[0].startBeat, 0.5, accuracy: 0.0001)
    }

    func testOtherFieldsAreUnchanged() {
        let note = NoteEvent(pitch: 67, velocity: 88, startBeat: 0.3, lengthBeats: 1.5)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].id, note.id)
        XCTAssertEqual(result[0].pitch, 67)
        XCTAssertEqual(result[0].velocity, 88)
        XCTAssertEqual(result[0].lengthBeats, 1.5, accuracy: 0.0001)
    }

    func testZeroOrNegativeGridReturnsNotesUnchanged() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let resultZero = Quantizer.quantize([note], gridBeats: 0, strength: 1)
        let resultNegative = Quantizer.quantize([note], gridBeats: -0.25, strength: 1)
        XCTAssertEqual(resultZero[0].startBeat, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resultNegative[0].startBeat, 0.3, accuracy: 0.0001)
    }

    func testStrengthIsClampedOutsideZeroToOne() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.30, lengthBeats: 1)
        let overOne = Quantizer.quantize([note], gridBeats: 0.25, strength: 2.0)
        let underZero = Quantizer.quantize([note], gridBeats: 0.25, strength: -1.0)
        XCTAssertEqual(overOne[0].startBeat, 0.25, accuracy: 0.0001)   // same as strength 1
        XCTAssertEqual(underZero[0].startBeat, 0.3, accuracy: 0.0001) // same as strength 0
    }

    func testNonFiniteStrengthDoesNotProduceNonFiniteStartBeat() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let nanResult = Quantizer.quantize([note], gridBeats: 0.25, strength: .nan)
        let infResult = Quantizer.quantize([note], gridBeats: 0.25, strength: .infinity)

        XCTAssertTrue(nanResult[0].startBeat.isFinite)
        XCTAssertTrue(infResult[0].startBeat.isFinite)
        // Both non-finite strengths take the `isFinite` guard's no-change path, so both
        // leave startBeat at 0.3. Without that guard: NaN survives `min`/`max` (all NaN
        // comparisons are false) and poisons startBeat into NaN, while `.infinity` clamps
        // to 1 and hard-snaps to 0.25 — so both concrete assertions below fail if the
        // guard is removed.
        XCTAssertEqual(nanResult[0].startBeat, 0.3, accuracy: 0.0001)
        XCTAssertEqual(infResult[0].startBeat, 0.3, accuracy: 0.0001)
    }
}
