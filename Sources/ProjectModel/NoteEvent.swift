import Foundation

public struct NoteEvent: Codable, Equatable, Sendable {
    public var pitch: UInt8
    public var velocity: UInt8
    public var startBeat: Double
    public var lengthBeats: Double

    public init(pitch: UInt8, velocity: UInt8, startBeat: Double, lengthBeats: Double) {
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }
}
