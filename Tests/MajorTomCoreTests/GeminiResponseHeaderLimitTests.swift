import XCTest
@testable import MajorTomCore

final class GeminiResponseHeaderLimitTests: XCTestCase {
    private func events(forMetaOfLength length: Int) throws -> [GeminiResponseStreamDecoder.Event] {
        var decoder = GeminiResponseStreamDecoder()
        return try decoder.receive(Data("20 \(String(repeating: "a", count: length))\r\n".utf8))
    }

    /// Prevents the bug where the whole response line was held to `META`'s own 1024-byte
    /// limit, so the largest `META` Major Tom would accept was 1019 bytes and a
    /// conforming server sending a longer one failed with a protocol error.
    func testMetaOfTheMaximumLengthIsAccepted() throws {
        for length in [1_019, 1_020, 1_024] {
            let events = try events(forMetaOfLength: length)
            XCTAssertEqual(events.count, 1, "META of \(length) bytes should be accepted")
            guard case .header(let header) = events[0] else {
                return XCTFail("expected a header event for META of \(length) bytes")
            }
            XCTAssertEqual(header.status, 20)
            XCTAssertEqual(header.meta.utf8.count, length)
        }
    }

    func testMetaBeyondTheMaximumLengthIsRejected() {
        XCTAssertThrowsError(try events(forMetaOfLength: 1_025)) { error in
            XCTAssertEqual(error as? GeminiProtocolError, .responseHeaderTooLong)
        }
    }

    func testUnterminatedHeaderBeyondTheMaximumIsRejected() {
        var decoder = GeminiResponseStreamDecoder()
        let overlongLine = "20 " + String(repeating: "a", count: 1_100)
        XCTAssertThrowsError(try decoder.receive(Data(overlongLine.utf8))) { error in
            XCTAssertEqual(error as? GeminiProtocolError, .responseHeaderTooLong)
        }
    }

    /// The limit is a byte count, not a character count, so multi-byte `META` text must
    /// be measured in UTF-8 bytes.
    func testMetaLengthIsMeasuredInBytesRatherThanCharacters() throws {
        // "é" is two UTF-8 bytes, so 512 of them are exactly 1024 bytes.
        var decoder = GeminiResponseStreamDecoder()
        let meta = String(repeating: "é", count: 512)
        XCTAssertEqual(meta.utf8.count, 1_024)
        let events = try decoder.receive(Data("20 \(meta)\r\n".utf8))
        guard case .header(let header) = events.first else {
            return XCTFail("expected a header event")
        }
        XCTAssertEqual(header.meta, meta)
    }

    /// A body arriving in the same segment as a maximum-length header still reaches the
    /// caller, so the boundary case does not silently drop content.
    func testBodyInTheSameSegmentAsAMaximumLengthHeaderIsDelivered() throws {
        var decoder = GeminiResponseStreamDecoder()
        let meta = String(repeating: "a", count: 1_024)
        let events = try decoder.receive(Data("20 \(meta)\r\n# Hi".utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last, .body(Data("# Hi".utf8)))
    }
}
