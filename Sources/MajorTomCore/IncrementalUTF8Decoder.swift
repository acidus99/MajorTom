import Foundation

public struct IncrementalUTF8Decoder: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        pending.append(data)
        let retainedCount = trailingIncompleteSequenceLength(in: pending)
        let decodedCount = pending.count - retainedCount
        guard decodedCount > 0 else { return "" }

        let decoded = String(decoding: pending.prefix(decodedCount), as: UTF8.self)
        pending = Data(pending.suffix(retainedCount))
        return decoded
    }

    public mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: false) }
        return String(decoding: pending, as: UTF8.self)
    }

    private func trailingIncompleteSequenceLength(in data: Data) -> Int {
        guard let finalByte = data.last, finalByte >= 0x80 else { return 0 }

        var continuationCount = 0
        var index = data.count - 1
        while index > 0,
              continuationCount < 3,
              data[index] & 0b1100_0000 == 0b1000_0000 {
            continuationCount += 1
            index -= 1
        }

        let lead = data[index]
        let expectedLength: Int
        switch lead {
        case 0b1100_0000...0b1101_1111: expectedLength = 2
        case 0b1110_0000...0b1110_1111: expectedLength = 3
        case 0b1111_0000...0b1111_0111: expectedLength = 4
        default: return 0
        }

        let availableLength = data.count - index
        return availableLength < expectedLength ? availableLength : 0
    }
}
