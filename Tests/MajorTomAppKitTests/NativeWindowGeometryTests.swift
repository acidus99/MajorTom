import CoreGraphics
import XCTest
@testable import MajorTomAppKitSupport

final class NativeWindowGeometryTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1_280, height: 800)

    func testTinySavedFrameIsExpandedAndKeptOnscreen() throws {
        // Prevents a SwiftUI fitting-size frame from becoming the permanent launch size.
        let result = try XCTUnwrap(NativeWindowGeometry.resolve(
            savedFrame: CGRect(x: 0, y: 723, width: 244, height: 112),
            visibleFrames: [display]
        ))

        XCTAssertGreaterThanOrEqual(result.frame.width, 652)
        XCTAssertGreaterThanOrEqual(result.frame.height, 710)
        XCTAssertTrue(display.contains(result.frame))
        XCTAssertTrue(result.adjustments.contains(.belowMinimum))
        XCTAssertTrue(result.adjustments.contains(.movedOnscreen))
    }

    func testValidSavedFrameIsUnchanged() throws {
        let saved = CGRect(x: 80, y: 20, width: 900, height: 740)
        let result = try XCTUnwrap(NativeWindowGeometry.resolve(
            savedFrame: saved,
            visibleFrames: [display]
        ))

        XCTAssertEqual(result.frame, saved)
        XCTAssertEqual(result.adjustments, [])
    }

    func testMissingFrameUsesCenteredNormalWindowSize() throws {
        let result = try XCTUnwrap(NativeWindowGeometry.resolve(
            savedFrame: nil,
            visibleFrames: [display]
        ))

        XCTAssertEqual(result.frame.size, CGSize(width: 1_100, height: 760))
        XCTAssertEqual(result.frame.midX, display.midX)
        XCTAssertEqual(result.frame.midY, display.midY)
        XCTAssertTrue(result.adjustments.contains(.missingFrame))
    }

    func testDisconnectedDisplayFrameMovesToClosestCurrentDisplay() throws {
        let result = try XCTUnwrap(NativeWindowGeometry.resolve(
            savedFrame: CGRect(x: 2_000, y: 100, width: 800, height: 710),
            visibleFrames: [display]
        ))

        XCTAssertTrue(display.contains(result.frame))
        XCTAssertTrue(result.adjustments.contains(.movedOnscreen))
    }

    func testOversizedFrameIsReducedToTheUsableDisplay() throws {
        let result = try XCTUnwrap(NativeWindowGeometry.resolve(
            savedFrame: CGRect(x: -100, y: -100, width: 1_600, height: 1_000),
            visibleFrames: [display]
        ))

        XCTAssertEqual(result.frame, display)
        XCTAssertTrue(result.adjustments.contains(.exceedsDisplay))
        XCTAssertTrue(result.adjustments.contains(.movedOnscreen))
    }

    func testInvalidFrameUsesCenteredDefault() throws {
        let result = try XCTUnwrap(NativeWindowGeometry.resolve(
            savedFrame: CGRect(x: CGFloat.nan, y: 0, width: 900, height: 710),
            visibleFrames: [display]
        ))

        XCTAssertTrue(display.contains(result.frame))
        XCTAssertEqual(result.frame.midX, display.midX)
        XCTAssertEqual(result.frame.midY, display.midY)
        XCTAssertTrue(result.adjustments.contains(.invalidFrame))
    }

    func testSmallDisplayCapsWindowToVisibleFrame() throws {
        let smallDisplay = CGRect(x: 0, y: 0, width: 600, height: 650)
        let result = try XCTUnwrap(NativeWindowGeometry.resolve(
            savedFrame: CGRect(x: 20, y: 20, width: 200, height: 200),
            visibleFrames: [smallDisplay]
        ))

        XCTAssertEqual(result.frame, smallDisplay)
        XCTAssertTrue(result.adjustments.contains(.belowMinimum))
        XCTAssertTrue(result.adjustments.contains(.movedOnscreen))
    }
}
