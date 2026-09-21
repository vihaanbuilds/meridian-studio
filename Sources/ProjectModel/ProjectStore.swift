import Foundation

public enum ProjectStoreError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidTempo(Double)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "This project was created with a newer, unsupported file format (schema version \(version))."
        case .invalidTempo(let tempo):
            return "This project has an invalid tempo (\(tempo)) and cannot be opened."
        }
    }
}

public enum ProjectStore {
    private static let projectFileName = "project.json"
    private static let midiDirectoryName = "midi"
    private static let audioDirectoryName = "audio"

    public static func save(_ project: Project, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: url.appendingPathComponent(midiDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: url.appendingPathComponent(audioDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: url.appendingPathComponent(projectFileName), options: .atomic)
    }

    public static func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url.appendingPathComponent(projectFileName))
        let project = try JSONDecoder().decode(Project.self, from: data)
        try migrate(project)
        return project
    }

    private static func migrate(_ project: Project) throws {
        guard project.schemaVersion == Project.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedSchemaVersion(project.schemaVersion)
        }
        // `ProjectDocument.setTempo` clamps tempo to a positive floor, but File > Open
        // bypasses it entirely: a hand-edited or corrupt project.json with tempo 0,
        // negative or non-finite would decode fine and then trap downstream in
        // `PlaybackEngine.play`'s `UInt64(seconds * 1e9)` conversion. Reject it here,
        // at the load boundary, so an invalid tempo can never enter the model.
        guard project.tempo.isFinite && project.tempo > 0 else {
            throw ProjectStoreError.invalidTempo(project.tempo)
        }
    }
}
