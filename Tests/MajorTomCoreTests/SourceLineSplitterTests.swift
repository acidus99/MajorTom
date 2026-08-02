import XCTest
@testable import MajorTomCore

final class SourceLineSplitterTests: XCTestCase {
    func testCRLFProducesOneLinePerLine() {
        XCTAssertEqual(
            SourceLineSplitter.lines(of: "one\r\ntwo\r\nthree"),
            ["one", "two", "three"]
        )
    }

    func testLFAndCRLFAgree() {
        XCTAssertEqual(
            SourceLineSplitter.lines(of: "one\ntwo\nthree"),
            SourceLineSplitter.lines(of: "one\r\ntwo\r\nthree")
        )
    }

    func testLoneCarriageReturnEndsALine() {
        XCTAssertEqual(SourceLineSplitter.lines(of: "one\rtwo"), ["one", "two"])
    }

    func testSingleTrailingTerminatorDoesNotAddAnEmptyLine() {
        XCTAssertEqual(SourceLineSplitter.lines(of: "one\ntwo\n"), ["one", "two"])
        XCTAssertEqual(SourceLineSplitter.lines(of: "one\r\ntwo\r\n"), ["one", "two"])
    }

    func testInteriorBlankLinesArePreserved() {
        XCTAssertEqual(SourceLineSplitter.lines(of: "one\n\ntwo"), ["one", "", "two"])
        XCTAssertEqual(SourceLineSplitter.lines(of: "one\r\n\r\ntwo"), ["one", "", "two"])
    }

    func testEmptySourceIsASingleEmptyLine() {
        XCTAssertEqual(SourceLineSplitter.lines(of: ""), [""])
    }

    /// Gemtext terminates lines with CRLF or LF. These scalars are matched by
    /// `Character.isNewline` but must not split a source line.
    func testUnicodeLineSeparatorsAreNotLineTerminators() {
        for scalar in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(
                SourceLineSplitter.lines(of: "a\(scalar)b"),
                ["a\(scalar)b"],
                "U+\(String(format: "%04X", scalar.unicodeScalars.first!.value)) must not split a line"
            )
        }
    }
}
