import Foundation

public enum ProjectStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

public enum ProjectStore {
    private static let projectFileName = "project.json"
    private static let midiDirectoryName = "midi"

    public static func save(_ project: Project, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: url.appendingPathComponent(midiDirectoryName, isDirectory: true),
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
    }
}
