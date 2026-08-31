import XCTest
@testable import MajorTomCore

final class LagrangeUserDataExportTests: XCTestCase {
    func testParsesBookmarksHomeIdentityAssignmentsAndTrust() throws {
        let files = [
            "lagrange-export.ini": Data("version = \"1.20.9\"".utf8),
            "bookmarks.ini": Data("[1]\nurl = \"gemini://example.com/path\"\ntitle = \"Example\"\ntags = \".homepage\"".utf8),
            "sitespec.ini": Data("[gemini://example.com/path]\nusedIdentities = \"abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd\"".utf8),
            "trusted.txt": Data("example.com;1965 1 abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd".utf8)
        ]
        let export = try LagrangeUserDataExport(files: files)
        XCTAssertEqual(export.version, "1.20.9")
        XCTAssertEqual(export.bookmarks.first?.title, "Example")
        XCTAssertTrue(export.bookmarks.first?.isHomepage == true)
        XCTAssertEqual(export.identityAssignments.first?.url.absoluteString, "gemini://example.com/path")
        XCTAssertEqual(export.trustedIdentities.first?.endpoint, CapsuleEndpoint(host: "example.com"))
    }

    func testRejectsUnknownMajorFormat() {
        XCTAssertThrowsError(try LagrangeUserDataExport(files: [
            "lagrange-export.ini": Data("version = \"2.0\"".utf8),
            "bookmarks.ini": Data()
        ]))
    }
}
