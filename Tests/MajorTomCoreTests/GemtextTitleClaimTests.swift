import Foundation
import XCTest
@testable import MajorTomCore

final class GemtextTitleClaimTests: XCTestCase {
    private func claim(_ events: [GemtextEvent], existingTitle: String? = nil) -> GemtextTitleClaim {
        var claim = GemtextTitleClaim(existingTitle: existingTitle)
        for event in events { _ = claim.receive(event) }
        return claim
    }

    func testNothingClaimsAnUntitledDocument() {
        let result = claim([.text("just prose"), .blank, .listItem("an item")])
        XCTAssertNil(result.title)
        XCTAssertEqual(result.source, .none)
    }

    func testLevelOneHeadingClaimsTheTitle() {
        let result = claim([.heading(level: 1, text: "Capsule Log")])
        XCTAssertEqual(result.title, "Capsule Log")
        XCTAssertEqual(result.source, .heading)
    }

    func testFirstHeadingOfAnyLevelClaimsTheTitle() {
        let result = claim([.heading(level: 2, text: "Section"), .heading(level: 3, text: "Sub")])
        XCTAssertEqual(result.title, "Section")
        XCTAssertEqual(result.source, .heading)
    }

    func testFirstHeadingWinsOverLaterHeadings() {
        let result = claim([
            .heading(level: 1, text: "First"),
            .heading(level: 1, text: "Second")
        ])
        XCTAssertEqual(result.title, "First")
    }

    func testPreformattedCaptionClaimsTheTitleWhenThereIsNoHeading() {
        let result = claim([
            .beginPreformatted(altText: "ASCII Banner"),
            .preformattedLine("|__|"),
            .endPreformatted
        ])
        XCTAssertEqual(result.title, "ASCII Banner")
        XCTAssertEqual(result.source, .preformattedAlt)
    }

    func testUnlabelledPreformattedBlockClaimsNothing() {
        let result = claim([.beginPreformatted(altText: nil), .endPreformatted])
        XCTAssertNil(result.title)
        XCTAssertEqual(result.source, .none)
    }

    func testNonTitleContentBeforeHeadingDoesNotCloseTheClaimWindow() {
        let result = claim([.text("introductory prose"), .heading(level: 1, text: "Later")])
        XCTAssertEqual(result.title, "Later")
        XCTAssertEqual(result.source, .heading)
    }

    func testHeadingAfterTheFifteenthLineIsIgnored() {
        let firstFourteen = Array(repeating: GemtextEvent.text("prose"), count: 14)
        let result = claim(firstFourteen + [.blank, .heading(level: 1, text: "Too Late")])
        XCTAssertNil(result.title)
        XCTAssertEqual(result.source, .none)
    }

    func testNonEmptyPreformattedContentWithoutCaptionDoesNotCloseTheClaimWindow() {
        let result = claim([
            .beginPreformatted(altText: nil),
            .preformattedLine("ASCII art"),
            .heading(level: 1, text: "Later")
        ])
        XCTAssertEqual(result.title, "Later")
        XCTAssertEqual(result.source, .heading)
    }

    func testOnlyTheFirstPreformattedCaptionIsUsed() {
        let result = claim([
            .beginPreformatted(altText: "First Banner"),
            .endPreformatted,
            .beginPreformatted(altText: "Second Banner"),
            .endPreformatted
        ])
        XCTAssertEqual(result.title, "First Banner")
    }

    /// The streaming case that motivates the whole type: the fence arrives first and
    /// claims the title, then a real heading must take it over.
    func testHeadingOutranksAnEarlierPreformattedCaption() {
        var claim = GemtextTitleClaim()
        XCTAssertTrue(claim.receive(.beginPreformatted(altText: "Banner")))
        XCTAssertEqual(claim.title, "Banner")
        XCTAssertTrue(claim.receive(.heading(level: 1, text: "Real Title")))
        XCTAssertEqual(claim.title, "Real Title")
        XCTAssertEqual(claim.source, .heading)
    }

    func testPreformattedCaptionCannotDisplaceAHeading() {
        let result = claim([
            .heading(level: 1, text: "Real Title"),
            .beginPreformatted(altText: "Banner")
        ])
        XCTAssertEqual(result.title, "Real Title")
    }

    func testBlankHeadingDoesNotLockOutALaterCaption() {
        let result = claim([
            .heading(level: 1, text: "   "),
            .beginPreformatted(altText: "Banner")
        ])
        XCTAssertEqual(result.title, "Banner")
    }

    func testTitlesAreTrimmed() {
        XCTAssertEqual(claim([.heading(level: 1, text: "  Spaced  ")]).title, "Spaced")
    }

    func testReceiveReportsWhetherTheTitleChanged() {
        var claim = GemtextTitleClaim()
        XCTAssertTrue(claim.receive(.heading(level: 1, text: "Title")))
        XCTAssertFalse(claim.receive(.text("body")))
        XCTAssertFalse(claim.receive(.heading(level: 1, text: "Another")))
    }

    // MARK: - Seeding from cache

    func testSeededTitleIsHeldAtHeadingStrength() {
        let result = claim([.beginPreformatted(altText: "Banner")], existingTitle: "Cached Title")
        XCTAssertEqual(result.title, "Cached Title")
        XCTAssertEqual(result.source, .heading)
    }

    func testSeedingWithNothingLeavesTheClaimOpen() {
        let result = claim([.beginPreformatted(altText: "Banner")], existingTitle: nil)
        XCTAssertEqual(result.title, "Banner")
    }

    func testSeedingWithBlankLeavesTheClaimOpen() {
        let result = claim([.heading(level: 1, text: "Real")], existingTitle: "   ")
        XCTAssertEqual(result.title, "Real")
    }

    /// Re-offering the same title promotes the claim's strength without reporting a
    /// change, so a cached page re-rendered twice cannot flip its title.
    func testRepeatingTheTitlePromotesTheClaimWithoutChanging() {
        var claim = GemtextTitleClaim()
        XCTAssertTrue(claim.receive(.beginPreformatted(altText: "Same")))
        XCTAssertEqual(claim.source, .preformattedAlt)
        XCTAssertFalse(claim.receive(.heading(level: 1, text: "Same")))
        XCTAssertEqual(claim.source, .heading)
        XCTAssertEqual(claim.title, "Same")
    }
}
