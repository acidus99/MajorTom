import Foundation

public struct GeminiResponseStreamDecoder: Sendable {
    public enum Event: Equatable, Sendable {
        case header(GeminiResponseHeader)
        case body(Data)
    }

    /// A response header is `<STATUS><SPACE><META><CR><LF>` and `META` may itself be
    /// 1024 bytes, so the whole line runs to 2 + 1 + 1024 + 2 bytes.
    ///
    /// Capping the line at `META`'s own limit instead rejected conforming responses:
    /// the effective ceiling was 1019 bytes of `META`, and a server sending a longer
    /// prompt, error explanation or redirect target failed with a protocol error.
    public static let maximumMetaByteCount = 1_024
    public static let maximumHeaderByteCount = maximumMetaByteCount + 5

    private var headerBuffer = Data()
    private var parsedHeader: GeminiResponseHeader?
    private var isFinished = false

    public init() {}

    public mutating func receive(_ data: Data) throws -> [Event] {
        guard !isFinished else {
            throw GeminiProtocolError.receivedDataAfterCompletion
        }
        guard !data.isEmpty else { return [] }

        if parsedHeader != nil {
            return [.body(data)]
        }

        headerBuffer.append(data)
        let terminator = Data([0x0D, 0x0A])

        guard let terminatorRange = headerBuffer.range(of: terminator) else {
            if headerBuffer.count > Self.maximumHeaderByteCount {
                throw GeminiProtocolError.responseHeaderTooLong
            }
            return []
        }

        guard terminatorRange.upperBound <= Self.maximumHeaderByteCount else {
            throw GeminiProtocolError.responseHeaderTooLong
        }

        let lineData = headerBuffer[..<terminatorRange.lowerBound]
        let header = try GeminiResponseHeader(lineData: Data(lineData))
        parsedHeader = header

        var events: [Event] = [.header(header)]
        let body = headerBuffer[terminatorRange.upperBound...]
        if !body.isEmpty {
            events.append(.body(Data(body)))
        }
        headerBuffer.removeAll(keepingCapacity: false)
        return events
    }

    public mutating func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        guard parsedHeader != nil else {
            throw GeminiProtocolError.responseEndedBeforeHeader
        }
    }
}
