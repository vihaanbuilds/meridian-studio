import Foundation

public struct NoteEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var pitch: UInt8
    public var velocity: UInt8
    public var startBeat: Double
    public var lengthBeats: Double

    public init(id: UUID = UUID(), pitch: UInt8, velocity: UInt8, startBeat: Double, lengthBeats: Double) {
        self.id = id
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }

    // Equality intentionally ignores `id` — existing code (recording, persistence,
    // tests) compares NoteEvents by musical content, not instance identity. `id`
    // exists only so the piano roll can address a specific note for editing/deletion.
    public static func == (lhs: NoteEvent, rhs: NoteEvent) -> Bool {
        lhs.pitch == rhs.pitch && lhs.velocity == rhs.velocity
            && lhs.startBeat == rhs.startBeat && lhs.lengthBeats == rhs.lengthBeats
    }

    private enum CodingKeys: String, CodingKey {
        case id, pitch, velocity, startBeat, lengthBeats
    }

    // Custom decode so a project file saved before this field existed still opens:
    // `id` is synthesized fresh when absent rather than failing to decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pitch = try container.decode(UInt8.self, forKey: .pitch)
        velocity = try container.decode(UInt8.self, forKey: .velocity)
        startBeat = try container.decode(Double.self, forKey: .startBeat)
        lengthBeats = try container.decode(Double.self, forKey: .lengthBeats)
    }
}
