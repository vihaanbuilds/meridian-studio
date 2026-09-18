// Tests/ProjectModelTests/ProjectDocumentTests.swift
import XCTest
@testable import ProjectModel

@MainActor
final class ProjectDocumentTests: XCTestCase {
    func testAddRegionAppendsToTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [])
        doc.addRegion(region, toTrackAt: 0)
        XCTAssertEqual(doc.project.tracks[0].regions.count, 1)
    }

    func testUndoRemovesRecordedRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [])
        doc.addRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].regions.count, 0)
    }

    func testRedoReAddsRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [])
        doc.addRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks[0].regions.count, 1)
    }

    func testSetTempoUpdatesProject() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTempo(140)
        XCTAssertEqual(doc.project.tempo, 140)
    }

    // Regression guards for the tempo clamp. A zero/negative/non-finite tempo makes
    // `Tempo.seconds(forBeats:tempo:)` produce NaN or Infinity, which traps in
    // `PlaybackEngine.play`'s `UInt64(seconds * 1e9)` conversion.

    func testSetTempoFloorsNaNToPositiveMinimum() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTempo(Double.nan)
        // Swift's `max` does not clamp NaN (all NaN comparisons are false), so this
        // specifically guards the explicit `isFinite` branch.
        XCTAssertEqual(doc.project.tempo, 1)
        XCTAssertTrue(doc.project.tempo.isFinite)
    }

    func testSetTempoFloorsZeroToPositiveMinimum() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTempo(0)
        XCTAssertEqual(doc.project.tempo, 1)
    }

    func testSetTempoFloorsNegativeToPositiveMinimum() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTempo(-5)
        XCTAssertEqual(doc.project.tempo, 1)
    }

    func testSetTempoFloorsInfinityToPositiveMinimum() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTempo(.infinity)
        XCTAssertEqual(doc.project.tempo, 1)
    }

    func testSetTempoLeavesNormalValueUnchanged() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTempo(93.5)
        XCTAssertEqual(doc.project.tempo, 93.5)
    }
}
