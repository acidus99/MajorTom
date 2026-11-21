import Foundation
import XCTest
@testable import MajorTomCore

final class BrowserByteCountTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    /// Small pages must retain their exact size instead of rounding to kilobytes.
    func testExactBytesThrough9999() {
        XCTAssertEqual(BrowserByteCount.formatted(0, locale: english), "0 bytes")
        XCTAssertEqual(BrowserByteCount.formatted(1, locale: english), "1 byte")
        XCTAssertEqual(BrowserByteCount.formatted(1_024, locale: english), "1,024 bytes")
        XCTAssertEqual(BrowserByteCount.formatted(9_999, locale: english), "9,999 bytes")
    }

    /// File sizes use decimal scaling and exactly three significant digits.
    func testLargerSizesUseDecimalUnitsAndPreserveSignificantZeros() {
        let examples: [(Int, String)] = [
            (10_000, "10.0 KB"), (10_234, "10.2 KB"), (123_456, "123 KB"),
            (1_000_000, "1.00 MB"), (1_234_567, "1.23 MB"),
            (1_000_000_000, "1.00 GB"), (1_000_000_000_000, "1.00 TB"),
            (1_000_000_000_000_000, "1.00 PB"), (Int.max, "9.22 EB")
        ]
        for (bytes, expected) in examples {
            XCTAssertEqual(BrowserByteCount.formatted(bytes, locale: english), expected, "\(bytes) bytes")
        }
    }

    /// Rounding across a unit boundary must not leave a four-digit size label.
    func testRoundingPromotesToTheNextUnit() {
        XCTAssertEqual(BrowserByteCount.formatted(999_499, locale: english), "999 KB")
        XCTAssertEqual(BrowserByteCount.formatted(999_500, locale: english), "1.00 MB")
        XCTAssertEqual(BrowserByteCount.formatted(999_500_000, locale: english), "1.00 GB")
    }

    func testNumbersAndUnitsFollowTheLocale() {
        let french = Locale(identifier: "fr_FR")
        // Foundation supplies localized unit names as well as the decimal separator.
        for (bytes, expected) in [(1, "1 octet"), (10_234, "10,2 ko"), (1_000_000, "1,00 Mo")] {
            let result = BrowserByteCount.formatted(bytes, locale: french)
            XCTAssertEqual(result.split(whereSeparator: \.isWhitespace).joined(separator: " "), expected)
        }
    }
}
