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

    /// Copies every file inside `source`'s `audio/` directory into
    /// `destination`'s `audio/` directory. `destination`'s `audio/` directory
    /// must already exist (created by `save`) — called by Save As, where
    /// recorded audio otherwise stays behind at the old bundle while the new
    /// bundle's `project.json` still references filenames that don't exist
    /// there. A no-op if `source` has no `audio/` directory (nothing was ever
    /// recorded) or if `source` and `destination` are the same location.
    public static func copyAudioFiles(from source: URL, to destination: URL) throws {
        guard source != destination else { return }
        let fileManager = FileManager.default
        let sourceAudioDirectory = source.appendingPathComponent(audioDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: sourceAudioDirectory.path) else { return }
        let destinationAudioDirectory = destination.appendingPathComponent(audioDirectoryName, isDirectory: true)
        for file in try fileManager.contentsOfDirectory(at: sourceAudioDirectory, includingPropertiesForKeys: nil) {
            let destinationFile = destinationAudioDirectory.appendingPathComponent(file.lastPathComponent)
            if fileManager.fileExists(atPath: destinationFile.path) {
                try fileManager.removeItem(at: destinationFile)
            }
            try fileManager.copyItem(at: file, to: destinationFile)
        }
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
