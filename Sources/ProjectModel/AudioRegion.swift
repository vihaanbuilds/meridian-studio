import Foundation

public struct AudioRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    /// Filename only, never an absolute path — resolved against the project
    /// bundle's `audio/` directory by the app layer, so a bundle can be
    /// moved/renamed on disk without invalidating it.
    public var fileName: String
    /// How far into the underlying file (in seconds) this region's playback
    /// starts. 0 for every region that predates this field and for any
    /// newly recorded/imported region — both play from the top of the
    /// file, matching the behavior this field didn't change.
    public var sourceOffsetSeconds: Double

    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double, fileName: String, sourceOffsetSeconds: Double = 0) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.fileName = fileName
        self.sourceOffsetSeconds = sourceOffsetSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, startBeat, lengthBeats, fileName, sourceOffsetSeconds
    }

    // Custom decode so a project file saved before this field existed still
    // opens: it defaults to 0 (play from the top) when absent, the same
    // pattern `Track.audioRegions` already uses for its own migration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startBeat = try container.decode(Double.self, forKey: .startBeat)
        lengthBeats = try container.decode(Double.self, forKey: .lengthBeats)
        fileName = try container.decode(String.self, forKey: .fileName)
        sourceOffsetSeconds = try container.decodeIfPresent(Double.self, forKey: .sourceOffsetSeconds) ?? 0
    }
}
