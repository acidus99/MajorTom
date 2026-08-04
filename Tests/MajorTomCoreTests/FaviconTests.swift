import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiFaviconTests: XCTestCase {
    func testASingleEmojiIsAccepted() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F346}"), "\u{1F346}")
    }

    /// "The document may optionally end in a newline… MUST be removed by the client."
    func testTrailingLineFeedIsRemoved() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F346}\n"), "\u{1F346}")
    }

    func testTrailingCRLFIsRemoved() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F346}\r\n"), "\u{1F346}")
    }

    /// Only one terminator is optional; a document with two is not conformant.
    func testTwoTrailingNewlinesAreRejected() {
        XCTAssertNil(GeminiFavicon.parse("\u{1F346}\n\n"))
    }

    func testSkinToneModifierCountsAsOneEmoji() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F44D}\u{1F3FD}"), "\u{1F44D}\u{1F3FD}")
    }

    /// A zero-width-joiner sequence is one grapheme cluster and one favicon.
    func testJoinedSequenceCountsAsOneEmoji() {
        let technologist = "\u{1F469}\u{200D}\u{1F4BB}"
        XCTAssertEqual(GeminiFavicon.parse(technologist), technologist)
    }

    func testFlagIsAccepted() {
        let flag = "\u{1F1FA}\u{1F1F8}"
        XCTAssertEqual(GeminiFavicon.parse(flag), flag)
    }

    /// A text-default symbol qualifies only with VARIATION SELECTOR-16.
    func testSymbolWithPresentationSelectorIsAccepted() {
        XCTAssertEqual(GeminiFavicon.parse("\u{2764}\u{FE0F}"), "\u{2764}\u{FE0F}")
    }

    // MARK: - Rejections

    func testMultipleEmojiAreRejected() {
        XCTAssertNil(GeminiFavicon.parse("\u{1F346}\u{1F680}"))
    }

    func testPlainTextIsRejected() {
        XCTAssertNil(GeminiFavicon.parse("hello"))
        XCTAssertNil(GeminiFavicon.parse("A"))
    }

    /// A digit is Emoji=Yes only as a keycap base, and must not render as a favicon.
    func testBareDigitIsRejected() {
        XCTAssertNil(GeminiFavicon.parse("1"))
        XCTAssertNil(GeminiFavicon.parse("#"))
        XCTAssertNil(GeminiFavicon.parse("*"))
    }

    func testEmptyDocumentIsRejected() {
        XCTAssertNil(GeminiFavicon.parse(""))
        XCTAssertNil(GeminiFavicon.parse("\n"))
    }

    func testWhitespaceIsNotStrippedAndSoIsRejected() {
        // Only a trailing newline is optional; a space is content, making this two
        // characters and non-conformant.
        XCTAssertNil(GeminiFavicon.parse(" \u{1F346}"))
        XCTAssertNil(GeminiFavicon.parse("\u{1F346} "))
    }

    func testPathIsAtTheServerRoot() {
        XCTAssertEqual(GeminiFavicon.path, "/favicon.txt")
    }
}

final class FaviconStoreTests: XCTestCase {
    private let endpoint = CapsuleEndpoint(host: "example.com", port: 1_965)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomFaviconTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(lifetime: TimeInterval = FaviconStore.defaultLifetime) -> FaviconStore {
        FaviconStore(fileURL: directory.appendingPathComponent("favicons.json"), lifetime: lifetime)
    }

    func testUnprobedCapsuleIsUnknown() async {
        let store = makeStore()
        let lookup = await store.favicon(for: endpoint)
        XCTAssertEqual(lookup, .unknown)
    }

    func testRecordedFaviconIsReturned() async throws {
        let store = makeStore()
        try await store.record("\u{1F346}", for: endpoint)
        let lookup = await store.favicon(for: endpoint)
        XCTAssertEqual(lookup, .known("\u{1F346}"))
    }

    /// The RFC asks that "no favicon" be remembered, so the capsule is not re-probed on
    /// every page view.
    func testAbsenceIsRemembered() async throws {
        let store = makeStore()
        try await store.record(nil, for: endpoint)
        let lookup = await store.favicon(for: endpoint)
        XCTAssertEqual(lookup, .absent)
    }

    func testExpiredRecordBecomesUnknownAgain() async throws {
        let store = makeStore(lifetime: 60)
        try await store.record("\u{1F346}", for: endpoint, at: Date(timeIntervalSince1970: 1_000))
        let stale = await store.favicon(for: endpoint, now: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(stale, .unknown)
        let fresh = await store.favicon(for: endpoint, now: Date(timeIntervalSince1970: 1_030))
        XCTAssertEqual(fresh, .known("\u{1F346}"))
    }

    func testExpiredAbsenceIsProbedAgain() async throws {
        let store = makeStore(lifetime: 60)
        try await store.record(nil, for: endpoint, at: Date(timeIntervalSince1970: 1_000))
        let stale = await store.favicon(for: endpoint, now: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(stale, .unknown)
    }

    func testRecordsSurviveReopening() async throws {
        let store = makeStore()
        try await store.record("\u{1F680}", for: endpoint)

        let reopened = makeStore()
        let lookup = await reopened.favicon(for: endpoint)
        XCTAssertEqual(lookup, .known("\u{1F680}"))
    }

    /// A host on another port is a different server per the RFC, so it gets its own entry.
    func testPortIsPartOfTheIdentity() async throws {
        let store = makeStore()
        try await store.record("\u{1F346}", for: endpoint)
        let other = await store.favicon(for: CapsuleEndpoint(host: "example.com", port: 1_966))
        XCTAssertEqual(other, .unknown)
    }

    func testClearingRemovesEverything() async throws {
        let store = makeStore()
        try await store.record("\u{1F346}", for: endpoint)
        try await store.removeAll()
        let lookup = await store.favicon(for: endpoint)
        XCTAssertEqual(lookup, .unknown)
        let count = await store.recordCount()
        XCTAssertEqual(count, 0)
    }

    func testClearingPersists() async throws {
        let store = makeStore()
        try await store.record("\u{1F346}", for: endpoint)
        try await store.removeAll()

        let reopened = makeStore()
        let count = await reopened.recordCount()
        XCTAssertEqual(count, 0)
    }

    func testKnownFaviconsExcludeAbsentAndStaleEntries() async throws {
        let store = makeStore(lifetime: 60)
        let base = Date(timeIntervalSince1970: 1_000)
        try await store.record("\u{1F346}", for: endpoint, at: base)
        try await store.record(nil, for: CapsuleEndpoint(host: "none.example", port: 1_965), at: base)
        try await store.record("\u{1F680}", for: CapsuleEndpoint(host: "old.example", port: 1_965), at: Date(timeIntervalSince1970: 0))

        let known = await store.knownFavicons(now: base.addingTimeInterval(10))
        XCTAssertEqual(known, [endpoint: "\u{1F346}"])
    }
}
