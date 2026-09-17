// Sources/MIDIEngine/CoreMIDIInput.swift
import CoreMIDI
import Darwin

public enum MIDIEngineError: Error {
    case clientCreationFailed(OSStatus)
    case portCreationFailed(OSStatus)
}

/// Thin adapter over the classic (MIDI 1.0) CoreMIDI API. Parses only
/// simple 3-byte channel messages starting at the beginning of a packet —
/// it does not handle running status or SysEx, which real keyboards
/// typically don't send for plain note on/off. That's a documented Phase 1
/// limitation (see docs/midi.md).
public final class CoreMIDIInput {
    public let queue = MIDIEventQueue()
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    public init() {}

    public func start() throws {
        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreate("MeridianStudio" as CFString, nil, nil, &newClient)
        guard clientStatus == noErr else { throw MIDIEngineError.clientCreationFailed(clientStatus) }
        client = newClient

        var newPort = MIDIPortRef()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let portStatus = MIDIInputPortCreate(client, "MeridianStudioInput" as CFString, Self.readProc, context, &newPort)
        guard portStatus == noErr else { throw MIDIEngineError.portCreationFailed(portStatus) }
        inputPort = newPort

        let sourceCount = MIDIGetNumberOfSources()
        for index in 0..<sourceCount {
            MIDIPortConnectSource(inputPort, MIDIGetSource(index), nil)
        }
    }

    public func stop() {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
        inputPort = 0
        client = 0
    }

    private static let readProc: MIDIReadProc = { packetListPointer, readProcRefCon, _ in
        guard let readProcRefCon else { return }
        let input = Unmanaged<CoreMIDIInput>.fromOpaque(readProcRefCon).takeUnretainedValue()

        let mutableListPointer = UnsafeMutablePointer(mutating: packetListPointer)
        var packetPointer = withUnsafeMutablePointer(to: &mutableListPointer.pointee.packet) { $0 }

        for _ in 0..<packetListPointer.pointee.numPackets {
            let hostTime = mach_absolute_time()
            let length = Int(packetPointer.pointee.length)
            withUnsafeBytes(of: packetPointer.pointee.data) { rawBuffer in
                var offset = 0
                while offset + 2 < length {
                    let status = rawBuffer[offset]
                    guard status & 0x80 != 0 else { offset += 1; continue }
                    let data1 = rawBuffer[offset + 1]
                    let data2 = rawBuffer[offset + 2]
                    input.queue.push(RawMIDIMessage(status: status, data1: data1, data2: data2, timestamp: hostTime))
                    offset += 3
                }
            }
            packetPointer = MIDIPacketNext(packetPointer)
        }
    }
}
