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

    // Quantizing a whole take is the feature's actual purpose, so these cover more
    // than the single note every other case above passes.

    func testMultipleNotesArePreservedInCountAndID() {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.1, lengthBeats: 1)
        let noteB = NoteEvent(pitch: 64, velocity: 90, startBeat: 0.9, lengthBeats: 1)
        let noteC = NoteEvent(pitch: 67, velocity: 80, startBeat: 1.6, lengthBeats: 1)
        let result = Quantizer.quantize([noteA, noteB, noteC], gridBeats: 0.5, strength: 1)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.id), [noteA.id, noteB.id, noteC.id])
        // Each note snaps independently on a 0.5 grid: 0.1/0.5 = 0.2 rounds to 0 * 0.5 = 0.0;
        // 0.9/0.5 = 1.8 rounds to 2 * 0.5 = 1.0; 1.6/0.5 = 3.2 rounds to 3 * 0.5 = 1.5.
        XCTAssertEqual(result[0].startBeat, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result[1].startBeat, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result[2].startBeat, 1.5, accuracy: 0.0001)
    }

    func testNotesCollapsingToTheSameGridLineKeepDistinctIDs() {
        // Both land on the same grid line from opposite sides: 0.20/0.25 = 0.8 rounds to
        // 1 * 0.25 = 0.25, and 0.30/0.25 = 1.2 also rounds to 1 * 0.25 = 0.25. Neither note
        // is dropped or merged — quantize is a position edit, not a deduplication.
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.20, lengthBeats: 1)
        let noteB = NoteEvent(pitch: 64, velocity: 90, startBeat: 0.30, lengthBeats: 1)
        let result = Quantizer.quantize([noteA, noteB], gridBeats: 0.25, strength: 1)

        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].id, result[1].id)
        XCTAssertEqual(result[0].startBeat, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result[1].startBeat, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result[0].startBeat, result[1].startBeat, accuracy: 0.0001)
    }

    // `maxStartBeat` is the optional upper bound the UI supplies so a quantized note
    // cannot be pushed off the reachable canvas.

    func testMaxStartBeatHoldsAQuantizedNoteInsideTheBound() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 19.4, lengthBeats: 1)
        // 19.4/0.5 = 38.8 rounds to 39 * 0.5 = 19.5, which would put the note's end at
        // 20.5 — past the bound. The clamp pulls the start back to 20 - 1 = 19.
        let result = Quantizer.quantize([note], gridBeats: 0.5, strength: 1, maxStartBeat: 20)
        XCTAssertEqual(result[0].startBeat, 19.0, accuracy: 0.0001)
    }

    func testOmittingMaxStartBeatLeavesTheQuantizedPositionUnclamped() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 19.4, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.5, strength: 1)
        XCTAssertEqual(result[0].startBeat, 19.5, accuracy: 0.0001)
    }

    func testMaxStartBeatNeverPushesANoteBeforeBeatZero() {
        // A note longer than the whole bound: 4 - 8 is negative, so the clamp floors at 0
        // rather than dragging the note to a negative startBeat.
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 1.1, lengthBeats: 8)
        let result = Quantizer.quantize([note], gridBeats: 0.5, strength: 1, maxStartBeat: 4)
        XCTAssertEqual(result[0].startBeat, 0.0, accuracy: 0.0001)
    }
}
