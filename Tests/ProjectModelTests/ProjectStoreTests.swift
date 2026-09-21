import XCTest
@testable import ProjectModel

final class ProjectStoreTests: XCTestCase {
    private func makeTempBundleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Test.mstudio")
    }

    func testSaveAndLoadRoundTrips() throws {
        let project = Project(tracks: [Track(name: "Piano")])
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(project, to: url)
        let loaded = try ProjectStore.load(from: url)

        XCTAssertEqual(loaded, project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("midi").path))
    }

    /// `testSaveAndLoadRoundTrips` (and `CodableRoundTripTests`) compare notes with
    /// `NoteEvent`'s content-only `==`, which deliberately ignores `id` — so they
    /// would stay green even if every note id were dropped or regenerated on load.
    /// That would silently break selection/move/resize/delete for every reopened
    /// project, so assert on the ids specifically.
    func testSaveAndLoadPreservesNoteIDs() throws {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let noteB = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [noteA, noteB])
        let project = Project(tracks: [Track(name: "Piano", regions: [region])])
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(project, to: url)
        let loaded = try ProjectStore.load(from: url)

        let loadedIDs = Set(loaded.tracks[0].regions[0].notes.map(\.id))
        XCTAssertEqual(loadedIDs, [noteA.id, noteB.id])
    }

    /// `NoteEventTests.testDecodingWithoutIDSynthesizesOne` exercises a bare
    /// `JSONDecoder().decode(NoteEvent.self, ...)`; the real "open an old project"
    /// path is `ProjectStore.load` → `Project` → `Track` → `MIDIRegion` →
    /// `NoteEvent`. The two legacy notes below are byte-identical in musical content
    /// and carry no `id` key, so this also pins down that identical legacy notes get
    /// DISTINCT synthesized ids — what `PianoRollView`'s `ForEach(notes)` relies on
    /// for correct SwiftUI view identity.
    func testLoadSynthesizesDistinctIDsForLegacyNotesWithoutID() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let legacyJSON = """
        {"schemaVersion": 1, "sampleRate": 44100, "tempo": 120, "timeSignature": {"numerator": 4, "denominator": 4}, "tracks": [{"id": "11111111-1111-1111-1111-111111111111", "name": "Piano", "kind": "midi", "muted": false, "solo": false, "regions": [{"id": "22222222-2222-2222-2222-222222222222", "startBeat": 0, "lengthBeats": 4, "notes": [{"pitch": 60, "velocity": 100, "startBeat": 0, "lengthBeats": 1}, {"pitch": 60, "velocity": 100, "startBeat": 0, "lengthBeats": 1}]}]}]}
        """
        try legacyJSON.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let loaded = try ProjectStore.load(from: url)

        let notes = loaded.tracks[0].regions[0].notes
        XCTAssertEqual(notes.count, 2)
        XCTAssertNotEqual(notes[0].id, notes[1].id)
    }

    func testLoadRejectsUnsupportedSchemaVersion() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let futureVersionJSON = """
        {"schemaVersion": 999, "sampleRate": 44100, "tempo": 120, "timeSignature": {"numerator": 4, "denominator": 4}, "tracks": []}
        """
        try futureVersionJSON.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectStore.load(from: url)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .unsupportedSchemaVersion(999))
        }
    }

    /// File > Open bypasses `ProjectDocument.setTempo`'s clamping entirely, so a
    /// hand-edited project.json is the one path by which a zero/negative tempo can
    /// still reach `PlaybackEngine.play` and trap on `UInt64(seconds * 1e9)`.
    func testLoadRejectsZeroTempo() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let zeroTempoJSON = """
        {"schemaVersion": 1, "sampleRate": 44100, "tempo": 0, "timeSignature": {"numerator": 4, "denominator": 4}, "tracks": []}
        """
        try zeroTempoJSON.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectStore.load(from: url)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .invalidTempo(0))
        }
    }

    func testLoadRejectsNegativeTempo() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let negativeTempoJSON = """
        {"schemaVersion": 1, "sampleRate": 44100, "tempo": -120, "timeSignature": {"numerator": 4, "denominator": 4}, "tracks": []}
        """
        try negativeTempoJSON.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectStore.load(from: url)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .invalidTempo(-120))
        }
    }

    func testProjectStoreErrorsHaveUserFacingDescriptions() {
        // `ProjectDocumentIO.presentError` shows these via `NSAlert(error:)`, which
        // reads `localizedDescription` — i.e. `LocalizedError.errorDescription`.
        XCTAssertEqual(
            ProjectStoreError.unsupportedSchemaVersion(999).errorDescription,
            "This project was created with a newer, unsupported file format (schema version 999)."
        )
        XCTAssertEqual(
            ProjectStoreError.invalidTempo(0).errorDescription,
            "This project has an invalid tempo (0.0) and cannot be opened."
        )
    }

    func testSaveCreatesAudioDirectory() throws {
        let project = Project(tracks: [Track(name: "Piano")])
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(project, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("audio").path))
    }

    func testCopyAudioFilesCopiesExistingFiles() throws {
        let sourceURL = makeTempBundleURL()
        let destinationURL = makeTempBundleURL()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try ProjectStore.save(Project(tracks: [Track(name: "Piano")]), to: sourceURL)
        try ProjectStore.save(Project(tracks: [Track(name: "Piano")]), to: destinationURL)
        let sourceFile = sourceURL.appendingPathComponent("audio").appendingPathComponent("take1.wav")
        try Data("fake audio".utf8).write(to: sourceFile)

        try ProjectStore.copyAudioFiles(from: sourceURL, to: destinationURL)

        let destinationFile = destinationURL.appendingPathComponent("audio").appendingPathComponent("take1.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFile.path))
        XCTAssertEqual(try Data(contentsOf: destinationFile), Data("fake audio".utf8))
    }

    func testCopyAudioFilesNoOpsWhenSourceHasNoAudioDirectory() throws {
        let sourceURL = makeTempBundleURL()
        let destinationURL = makeTempBundleURL()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try ProjectStore.save(Project(tracks: [Track(name: "Piano")]), to: destinationURL)

        XCTAssertNoThrow(try ProjectStore.copyAudioFiles(from: sourceURL, to: destinationURL))
    }

    func testCopyAudioFilesNoOpsWhenSourceAndDestinationAreTheSame() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectStore.save(Project(tracks: [Track(name: "Piano")]), to: url)
        let file = url.appendingPathComponent("audio").appendingPathComponent("take1.wav")
        try Data("fake audio".utf8).write(to: file)

        XCTAssertNoThrow(try ProjectStore.copyAudioFiles(from: url, to: url))
        XCTAssertEqual(try Data(contentsOf: file), Data("fake audio".utf8))
    }
}
