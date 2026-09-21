import Foundation

public struct AudioRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    /// Filename only, never an absolute path — resolved against the project
    /// bundle's `audio/` directory by the app layer, so a bundle can be
    /// moved/renamed on disk without invalidating it.
    public var fileName: String

    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double, fileName: String) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.fileName = fileName
    }
}
