public struct Project: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sampleRate: Double
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var tracks: [Track]

    public init(
        sampleRate: Double = 44100,
        tempo: Double = 120,
        timeSignature: TimeSignature = TimeSignature(),
        tracks: [Track] = []
    ) {
        self.schemaVersion = Project.currentSchemaVersion
        self.sampleRate = sampleRate
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.tracks = tracks
    }
}
