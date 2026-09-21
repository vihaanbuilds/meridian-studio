import XCTest
import ProjectModel
@testable import MeridianCompanionApp

final class SessionLibraryTests: XCTestCase {
    private func makeTempSessionsDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeDate(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)!
    }

    func testSessionsDirectoryAppendsExpectedPath() {
        let base = URL(fileURLWithPath: "/tmp/base")
        let result = SessionLibrary.sessionsDirectory(baseDirectory: base)
        XCTAssertEqual(result.path, "/tmp/base/Meridian Companion/Sessions")
    }

    func testBundleURLFormatsTimestamp() {
        let sessionsDirectory = URL(fileURLWithPath: "/tmp/sessions")
        let date = makeDate("20260921-143007")
        let url = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        XCTAssertEqual(url.lastPathComponent, "Session-20260921-143007.mstudio")
    }

    func testParseSessionDateRoundTripsWithBundleURL() {
        let sessionsDirectory = URL(fileURLWithPath: "/tmp/sessions")
        let date = makeDate("20260921-143007")
        let url = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        let parsed = SessionLibrary.parseSessionDate(from: url.lastPathComponent)
        XCTAssertEqual(parsed, date)
    }

    func testParseSessionDateReturnsNilForMalformedFilename() {
        XCTAssertNil(SessionLibrary.parseSessionDate(from: "NotASession.mstudio"))
        XCTAssertNil(SessionLibrary.parseSessionDate(from: "Session-garbage.mstudio"))
        XCTAssertNil(SessionLibrary.parseSessionDate(from: "Session-20260921-143007.txt"))
    }

    func testLoadHistoryReturnsEmptyArrayWhenDirectoryDoesNotExist() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)
        XCTAssertTrue(result.isEmpty)
    }

    func testLoadHistoryLoadsMIDISessionDuration() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let date = makeDate("20260921-090000")
        let bundleURL = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 8, notes: [note])
        let track = Track(name: "Session", kind: .midi, regions: [region])
        let project = Project(tempo: 120, tracks: [track])
        try ProjectStore.save(project, to: bundleURL)

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].date, date)
        XCTAssertEqual(result[0].kind, .midi)
        XCTAssertEqual(result[0].durationSeconds, 4.0, accuracy: 0.001)
    }

    func testLoadHistoryLoadsAudioSessionDuration() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let date = makeDate("20260921-090000")
        let bundleURL = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take.wav")
        let track = Track(name: "Session", kind: .audio, audioRegions: [region])
        let project = Project(tempo: 120, tracks: [track])
        try ProjectStore.save(project, to: bundleURL)

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .audio)
        XCTAssertEqual(result[0].durationSeconds, 2.0, accuracy: 0.001)
    }

    func testLoadHistorySkipsMalformedFilenames() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sessionsDirectory.appendingPathComponent("NotASession.mstudio"),
            withIntermediateDirectories: true
        )

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertTrue(result.isEmpty)
    }

    func testLoadHistorySortsByDateAscending() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let laterDate = makeDate("20260922-090000")
        let earlierDate = makeDate("20260921-090000")
        let track = Track(name: "Session", kind: .midi, regions: [MIDIRegion(startBeat: 0, lengthBeats: 1)])
        let project = Project(tempo: 120, tracks: [track])
        try ProjectStore.save(project, to: SessionLibrary.bundleURL(for: laterDate, in: sessionsDirectory))
        try ProjectStore.save(project, to: SessionLibrary.bundleURL(for: earlierDate, in: sessionsDirectory))

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertEqual(result.map(\.date), [earlierDate, laterDate])
    }

    func testLoadHistorySkipsZeroDurationOrphanBundles() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let date = makeDate("20260921-090000")
        let bundleURL = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        // An empty-track project, exactly as `startSession()` writes before
        // any recording happens — this is what an orphaned bundle looks like.
        let track = Track(name: "Session", kind: .midi)
        let project = Project(tempo: 120, tracks: [track])
        try ProjectStore.save(project, to: bundleURL)

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertTrue(result.isEmpty)
    }

    func testMIDIRegionLengthBeatsSpansTheWholeTakeNotJustTheLastNote() {
        // Patient plays one short note, then leaves 9 beats of silence
        // before pressing Stop — the region must reflect the whole take.
        let notes = [NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)]
        let result = SessionLibrary.midiRegionLengthBeats(finalBeat: 10, notes: notes)
        XCTAssertEqual(result, 10)
    }

    func testMIDIRegionLengthBeatsUsesLastNoteEndWhenLaterThanFinalBeat() {
        let notes = [NoteEvent(pitch: 60, velocity: 100, startBeat: 8, lengthBeats: 4)]
        let result = SessionLibrary.midiRegionLengthBeats(finalBeat: 10, notes: notes)
        XCTAssertEqual(result, 12)
    }

    func testMIDIRegionLengthBeatsFloorsAtOneBeat() {
        let notes = [NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 0.1)]
        let result = SessionLibrary.midiRegionLengthBeats(finalBeat: 0.2, notes: notes)
        XCTAssertEqual(result, 1)
    }
}
