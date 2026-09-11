import Network
@testable import MajorTomCore
import XCTest

final class GeminiConnectionFailureTests: XCTestCase {
    func testClassifiesMissingDNSRecordWithoutExposingFrameworkError() {
        let failure = GeminiConnectionFailure.classify(.dns(-65_554))

        XCTAssertEqual(failure, .dnsRecordNotFound)
        XCTAssertFalse(failure.userFacingDescription.contains("-65554"))
    }

    func testClassifiesCommonConnectionFailures() {
        XCTAssertEqual(
            GeminiConnectionFailure.classify(.posix(.ECONNREFUSED)),
            .connectionRefused
        )
        XCTAssertEqual(
            GeminiConnectionFailure.classify(.posix(.ETIMEDOUT)),
            .connectionTimedOut
        )
        XCTAssertEqual(
            GeminiConnectionFailure.classify(.posix(.EHOSTUNREACH)),
            .hostUnreachable
        )
    }

    func testClassifiesTLSNegotiationFailure() {
        XCTAssertEqual(
            GeminiConnectionFailure.classify(.tls(errSSLNegotiation)),
            .tlsNegotiationFailed
        )
    }

    func testExplainsMalformedGeminiResponse() {
        XCTAssertTrue(GeminiProtocolError.malformedResponseHeader.userFacingDescription
            .contains("different protocol"))
    }
}
