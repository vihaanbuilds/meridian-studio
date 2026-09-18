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
}
