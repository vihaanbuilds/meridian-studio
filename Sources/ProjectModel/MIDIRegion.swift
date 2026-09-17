import Foundation

public struct MIDIRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    public var notes: [NoteEvent]

    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double, notes: [NoteEvent] = []) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.notes = notes
    }
}
