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

    func testAddTrackAppendsTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.addTrack(Track(name: "Bass"))
        XCTAssertEqual(doc.project.tracks.count, 2)
        XCTAssertEqual(doc.project.tracks[1].name, "Bass")
    }

    func testUndoRemovesAddedTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.addTrack(Track(name: "Bass"))
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks.count, 1)
        XCTAssertEqual(doc.project.tracks[0].name, "Piano")
    }

    func testRedoReAddsTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.addTrack(Track(name: "Bass"))
        doc.undoManager.undo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks.count, 2)
        XCTAssertEqual(doc.project.tracks[1].name, "Bass")
    }

    func testRemoveTrackRemovesByID() {
        let bass = Track(name: "Bass")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano"), bass]))
        doc.removeTrack(id: bass.id)
        XCTAssertEqual(doc.project.tracks.count, 1)
        XCTAssertEqual(doc.project.tracks[0].name, "Piano")
    }

    func testUndoReInsertsRemovedTrackAtOriginalIndex() {
        let bass = Track(name: "Bass")
        let drums = Track(name: "Drums")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano"), bass, drums]))
        doc.removeTrack(id: bass.id)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks.map(\.name), ["Piano", "Bass", "Drums"])
    }

    func testSetTrackMutedUpdatesTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTrackMuted(true, forTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].muted)
    }

    func testSetTrackSoloUpdatesTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTrackSolo(true, forTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].solo)
    }

    func testUpdateNoteReplacesMatchingNote() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        var updated = note
        updated.pitch = 64
        doc.updateNote(updated, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].pitch, 64)
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 1)
    }

    func testUpdateNoteIsNotUndoRegistered() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        var updated = note
        updated.pitch = 64
        doc.updateNote(updated, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testDeleteNotesRemovesMatchingNotes() {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let noteB = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [noteA, noteB])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.deleteNotes(ids: [noteA.id], inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 1)
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].id, noteB.id)
    }

    func testUndoRestoresDeletedNotes() {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let noteB = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [noteA, noteB])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.deleteNotes(ids: [noteA.id], inTrackAt: 0)
        doc.undoManager.undo()

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 2)
        XCTAssertTrue(doc.project.tracks[0].regions[0].notes.contains(where: { $0.id == noteA.id }))
    }

    func testRedoRemovesNotesAgain() {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [noteA])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.deleteNotes(ids: [noteA.id], inTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 0)
    }

    func testQuantizeNotesAppliesQuantizerToCurrentRegion() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.25, accuracy: 0.0001)
    }

    func testQuantizeNotesOnlyAffectsCurrentRegionNotEarlierOnes() {
        // Two regions, so this can distinguish `regions.last` (the current take, which
        // the piano roll shows) from `regions.first`.
        let earlierNote = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let earlierRegion = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [earlierNote])
        let currentNote = NoteEvent(pitch: 64, velocity: 90, startBeat: 0.3, lengthBeats: 1)
        let currentRegion = MIDIRegion(startBeat: 4, lengthBeats: 4, notes: [currentNote])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [earlierRegion, currentRegion])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.3, accuracy: 0.0001)  // untouched
        XCTAssertEqual(doc.project.tracks[0].regions[1].notes[0].startBeat, 0.25, accuracy: 0.0001) // quantized
    }

    func testQuantizeNotesIsNotUndoRegistered() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testQuantizeNotesNoOpsForOutOfRangeTrackIndex() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 5)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.3, accuracy: 0.0001)
    }

    func testQuantizeNotesNoOpsForTrackWithNoRegions() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        // Should not crash.
        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].regions.isEmpty)
    }

    func testAddAudioRegionAppendsRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio)]))
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        doc.addAudioRegion(region, toTrackAt: 0)
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].fileName, "take1.wav")
    }

    func testUndoRemovesAddedAudioRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio)]))
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        doc.addAudioRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        XCTAssertTrue(doc.project.tracks[0].audioRegions.isEmpty)
    }

    func testRedoReAddsAudioRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio)]))
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        doc.addAudioRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
    }

    func testRemoveAudioRegionRemovesByID() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio, audioRegions: [region])]))
        doc.removeAudioRegion(id: region.id, fromTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].audioRegions.isEmpty)
    }

    func testUndoReInsertsRemovedAudioRegion() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio, audioRegions: [region])]))
        doc.removeAudioRegion(id: region.id, fromTrackAt: 0)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].fileName, "take1.wav")
    }
}
