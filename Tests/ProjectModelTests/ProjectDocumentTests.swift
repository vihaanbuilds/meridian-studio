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
}
