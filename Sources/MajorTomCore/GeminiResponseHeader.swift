import Foundation

public struct GeminiResponseHeader: Equatable, Sendable {
    public let status: Int
    public let meta: String

    public init(status: Int, meta: String) throws {
        guard (10...69).contains(status) else {
            throw GeminiProtocolError.invalidStatus(status)
        }

        self.status = status
        self.meta = meta
    }

    public init(lineData: Data) throws {
        guard let line = String(data: lineData, encoding: .utf8) else {
            throw GeminiProtocolError.responseHeaderIsNotUTF8
        }

        guard line.utf8.count >= 3,
              let separator = line.firstIndex(of: " "),
              line.distance(from: line.startIndex, to: separator) == 2,
              let status = Int(line[..<separator]) else {
            throw GeminiProtocolError.malformedResponseHeader
        }

        try self.init(status: status, meta: String(line[line.index(after: separator)...]))
    }

    public var category: Int { status / 10 }
    public var isInput: Bool { category == 1 }
    public var isSuccess: Bool { category == 2 }
    public var isRedirect: Bool { category == 3 }
    public var isTemporaryFailure: Bool { category == 4 }
    public var isPermanentFailure: Bool { category == 5 }
    public var requiresClientCertificate: Bool { category == 6 }
}

public enum GeminiProtocolError: Error, Equatable, Sendable {
    case responseHeaderTooLong
    case responseEndedBeforeHeader
    case responseHeaderIsNotUTF8
    case malformedResponseHeader
    case invalidStatus(Int)
    case receivedDataAfterCompletion

    public var userFacingDescription: String {
        switch self {
        case .responseHeaderTooLong:
            return "The capsule sent a Gemini response header that is too large."
        case .responseEndedBeforeHeader:
            return "The capsule closed the connection before sending a complete Gemini response header."
        case .responseHeaderIsNotUTF8:
            return "The capsule's response header is not valid UTF-8, as required by Gemini."
        case .malformedResponseHeader:
            return "The capsule did not send a valid Gemini response header. It may be serving a different protocol on this port."
        case .invalidStatus:
            return "The capsule sent an unsupported Gemini status code."
        case .receivedDataAfterCompletion:
            return "The capsule sent data after completing its Gemini response."
        }
    }
}
