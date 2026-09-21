import Foundation

public enum TrackKind: String, Codable, Sendable {
    case midi
    case audio
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var muted: Bool
    public var solo: Bool
    public var regions: [MIDIRegion]
    public var audioRegions: [AudioRegion]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind = .midi,
        muted: Bool = false,
        solo: Bool = false,
        regions: [MIDIRegion] = [],
        audioRegions: [AudioRegion] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.muted = muted
        self.solo = solo
        self.regions = regions
        self.audioRegions = audioRegions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, muted, solo, regions, audioRegions
    }

    // Custom decode so a project file saved before `audioRegions` existed still
    // opens: it defaults to `[]` when absent, the same pattern already used for
    // `NoteEvent.id`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        muted = try container.decode(Bool.self, forKey: .muted)
        solo = try container.decode(Bool.self, forKey: .solo)
        regions = try container.decode([MIDIRegion].self, forKey: .regions)
        audioRegions = try container.decodeIfPresent([AudioRegion].self, forKey: .audioRegions) ?? []
    }
}
