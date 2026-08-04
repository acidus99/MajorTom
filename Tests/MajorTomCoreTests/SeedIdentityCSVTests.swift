import Foundation
import XCTest
@testable import MajorTomCore

final class SeedIdentityCSVTests: XCTestCase {
    private let fingerprint = String(repeating: "ab", count: 32)

    private func parse(_ text: String) -> Set<SeedServerIdentity> {
        SeedIdentityCSV.parse(text)
    }

    func testHeaderRowIsSkipped() {
        let parsed = parse("host,port,fingerprint\nexample.com,1965,\(fingerprint)")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.endpoint.host, "example.com")
    }

    /// The bug this covers: an untrimmed fingerprint failed the hex check, so a file
    /// written with spaces after the commas loaded as empty without complaint.
    func testWhitespaceAroundEveryFieldIsTolerated() {
        let parsed = parse("  example.com , 1965 , \(fingerprint)  ")
        XCTAssertEqual(
            parsed,
            [SeedServerIdentity(
                endpoint: CapsuleEndpoint(host: "example.com", port: 1_965),
                publicKeySHA256: fingerprint
            )]
        )
    }

    func testBlankLinesAreIgnored() {
        XCTAssertEqual(parse("\n\nexample.com,1965,\(fingerprint)\n\n").count, 1)
    }

    func testCRLFLineEndingsAreHandled() {
        let parsed = parse("example.com,1965,\(fingerprint)\r\nother.example,1965,\(fingerprint)")
        XCTAssertEqual(parsed.count, 2)
    }

    func testHostAndFingerprintAreNormalisedToLowercase() {
        let parsed = parse("EXAMPLE.COM,1965,\(fingerprint.uppercased())")
        XCTAssertEqual(parsed.first?.endpoint.host, "example.com")
        XCTAssertEqual(parsed.first?.publicKeySHA256, fingerprint)
    }

    func testDuplicateRowsCollapse() {
        XCTAssertEqual(parse("""
        example.com,1965,\(fingerprint)
        example.com,1965,\(fingerprint)
        """).count, 1)
    }

    /// Same host on another port is a different server, so both rows survive.
    func testSameHostOnDifferentPortsAreDistinct() {
        XCTAssertEqual(parse("""
        example.com,1965,\(fingerprint)
        example.com,1966,\(fingerprint)
        """).count, 2)
    }

    func testExtraColumnsAreIgnored() {
        XCTAssertEqual(parse("example.com,1965,\(fingerprint),added,later").count, 1)
    }

    // MARK: - Rejected rows

    func testRowsWithTooFewFieldsAreRejected() {
        XCTAssertTrue(parse("example.com,1965").isEmpty)
        XCTAssertTrue(parse("example.com").isEmpty)
    }

    func testNonNumericPortIsRejected() {
        XCTAssertTrue(parse("example.com,gemini,\(fingerprint)").isEmpty)
    }

    func testPortOutsideSixteenBitsIsRejected() {
        XCTAssertTrue(parse("example.com,70000,\(fingerprint)").isEmpty)
    }

    func testNonHexFingerprintIsRejected() {
        XCTAssertTrue(parse("example.com,1965,\(String(repeating: "z", count: 64))").isEmpty)
    }

    func testWrongLengthFingerprintIsRejected() {
        XCTAssertTrue(parse("example.com,1965,\(String(repeating: "ab", count: 31))").isEmpty)
        XCTAssertTrue(parse("example.com,1965,\(String(repeating: "ab", count: 33))").isEmpty)
    }

    func testEmptyHostIsRejected() {
        XCTAssertTrue(parse(",1965,\(fingerprint)").isEmpty)
    }

    /// One malformed row must not discard the rest of the file.
    func testAGoodRowSurvivesABadNeighbour() {
        let parsed = parse("""
        broken,notaport,\(fingerprint)
        example.com,1965,\(fingerprint)
        """)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.endpoint.host, "example.com")
    }

    func testEmptyInputYieldsNoSeeds() {
        XCTAssertTrue(parse("").isEmpty)
        XCTAssertTrue(parse("host,port,fingerprint").isEmpty)
    }
}
