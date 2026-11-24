import XCTest
@testable import MajorTomCore

final class AppVersionTests: XCTestCase {
    func testDevelopmentIsIdentifiedByBuildRatherThanPlaceholderReleaseVersion() {
        XCTAssertEqual(AppVersion.label(shortVersion: "0.0.0", buildNumber: "328", development: true),
                       "Development Build 328")
        XCTAssertEqual(AppVersion.label(shortVersion: "0.0.0", buildNumber: "0", development: true),
                       "Local Development Build")
    }

    func testProductionHidesBuildNumberAndOnlyOmitsZeroPatchComponent() {
        XCTAssertEqual(AppVersion.label(shortVersion: "1.4.0", buildNumber: "329", development: false),
                       "Version 1.4")
        XCTAssertEqual(AppVersion.label(shortVersion: "1.4.1", buildNumber: "330", development: false),
                       "Version 1.4.1")
        XCTAssertEqual(AppVersion.label(shortVersion: "1.10.0", buildNumber: "331", development: false),
                       "Version 1.10")
    }
}
