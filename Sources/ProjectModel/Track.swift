import Foundation

public enum TrackKind: String, Codable, Sendable {
    case midi
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var muted: Bool
    public var solo: Bool
    public var regions: [MIDIRegion]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind = .midi,
        muted: Bool = false,
        solo: Bool = false,
        regions: [MIDIRegion] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.muted = muted
        self.solo = solo
        self.regions = regions
    }
}
