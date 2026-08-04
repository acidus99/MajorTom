import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiInputBudgetTests: XCTestCase {
    private func budget(_ urlString: String) -> GeminiInputBudget {
        GeminiInputBudget(promptURL: URL(string: urlString)!)
    }

    func testBudgetIsTheRequestLimitLessTheURLAndItsQuestionMark() {
        let url = "gemini://example.com/ask"
        let expected = GeminiRequestTarget.maximumURLByteCount - url.utf8.count - 1
        XCTAssertEqual(budget(url).maximumEncodedByteCount, expected)
    }

    /// A prompt deep in a capsule leaves less room for the answer than one at the root.
    func testALongerPromptURLLeavesLessRoom() {
        let shallow = budget("gemini://example.com/a").maximumEncodedByteCount
        let deep = budget("gemini://example.com/a/very/long/path/to/the/prompt").maximumEncodedByteCount
        XCTAssertLessThan(deep, shallow)
    }

    /// The answer replaces any existing query, so an existing one must not be charged
    /// against the budget.
    func testExistingQueryIsNotChargedToTheBudget() {
        XCTAssertEqual(
            budget("gemini://example.com/ask?previous+answer").maximumEncodedByteCount,
            budget("gemini://example.com/ask").maximumEncodedByteCount
        )
    }

    func testFragmentIsNotChargedToTheBudget() {
        XCTAssertEqual(
            budget("gemini://example.com/ask#section").maximumEncodedByteCount,
            budget("gemini://example.com/ask").maximumEncodedByteCount
        )
    }

    func testBudgetNeverGoesNegative() {
        let absurd = "gemini://example.com/" + String(repeating: "x", count: 4_000)
        XCTAssertEqual(budget(absurd).maximumEncodedByteCount, 0)
    }

    // MARK: - Measuring the answer

    func testPlainASCIICostsOneByteEachCharacter() {
        XCTAssertEqual(budget("gemini://example.com/ask").encodedByteCount(of: "hello"), 5)
    }

    /// The reason a character count will not do: the space becomes %20, so three typed
    /// characters cost five bytes on the wire.
    func testEncodedCharactersCostThreeBytesEach() {
        XCTAssertEqual(budget("gemini://example.com/ask").encodedByteCount(of: "a b"), 5)
    }

    /// A non-BMP emoji is four UTF-8 bytes, each percent-encoded to three characters.
    func testAstralEmojiCostsTwelveBytes() {
        XCTAssertEqual(budget("gemini://example.com/ask").encodedByteCount(of: "\u{1F680}"), 12)
    }

    func testEmptyAnswerCostsNothing() {
        let subject = budget("gemini://example.com/ask")
        XCTAssertEqual(subject.encodedByteCount(of: ""), 0)
        XCTAssertEqual(subject.remainingByteCount(for: ""), subject.maximumEncodedByteCount)
    }

    // MARK: - Permitting

    func testAnAnswerExactlyFillingTheBudgetIsPermitted() {
        let subject = budget("gemini://example.com/ask")
        let answer = String(repeating: "a", count: subject.maximumEncodedByteCount)
        XCTAssertEqual(subject.remainingByteCount(for: answer), 0)
        XCTAssertTrue(subject.permits(answer))
    }

    func testOneByteTooManyIsRefused() {
        let subject = budget("gemini://example.com/ask")
        let answer = String(repeating: "a", count: subject.maximumEncodedByteCount + 1)
        XCTAssertEqual(subject.remainingByteCount(for: answer), -1)
        XCTAssertFalse(subject.permits(answer))
    }

    /// The budget must agree with the request builder: an answer it permits has to
    /// produce a target the transport accepts, and one it refuses must not.
    func testBudgetAgreesWithRequestConstruction() throws {
        let promptURL = URL(string: "gemini://example.com/ask")!
        let subject = GeminiInputBudget(promptURL: promptURL)

        let fitting = String(repeating: "a", count: subject.maximumEncodedByteCount)
        let fittingURL = GeminiQueryEncoding.url(base: promptURL, query: fitting)!
        XCTAssertNoThrow(try GeminiRequestTarget(fittingURL.absoluteString))

        let overlong = String(repeating: "a", count: subject.maximumEncodedByteCount + 1)
        let overlongURL = GeminiQueryEncoding.url(base: promptURL, query: overlong)!
        XCTAssertThrowsError(try GeminiRequestTarget(overlongURL.absoluteString)) { error in
            XCTAssertEqual(error as? GeminiRequestError, .urlTooLong)
        }
    }
}
