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
}
