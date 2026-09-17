public struct RawMIDIMessage: Equatable, Sendable {
    public var status: UInt8
    public var data1: UInt8
    public var data2: UInt8
    public var timestamp: UInt64

    public init(status: UInt8, data1: UInt8, data2: UInt8, timestamp: UInt64) {
        self.status = status
        self.data1 = data1
        self.data2 = data2
        self.timestamp = timestamp
    }
}
