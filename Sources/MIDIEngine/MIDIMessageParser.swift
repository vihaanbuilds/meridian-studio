// Sources/MIDIEngine/MIDIMessageParser.swift
public enum ParsedMIDIEvent: Equatable, Sendable {
    case noteOn(pitch: UInt8, velocity: UInt8, timestamp: UInt64)
    case noteOff(pitch: UInt8, timestamp: UInt64)
    case other
}

public enum MIDIMessageParser {
    public static func parse(_ message: RawMIDIMessage) -> ParsedMIDIEvent {
        switch message.status & 0xF0 {
        case 0x90:
            if message.data2 == 0 {
                return .noteOff(pitch: message.data1, timestamp: message.timestamp)
            }
            return .noteOn(pitch: message.data1, velocity: message.data2, timestamp: message.timestamp)
        case 0x80:
            return .noteOff(pitch: message.data1, timestamp: message.timestamp)
        default:
            return .other
        }
    }
}
