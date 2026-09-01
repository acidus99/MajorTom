import XCTest
@testable import MajorTomCore

final class AlhenaUserDataExportTests: XCTestCase {
    func testParsesBookmarksIdentitiesAndPreferencesWithoutExecutingSQL() throws {
        let script = #"""
        CREATE CACHED TABLE "PUBLIC"."BOOKMARKS"("ID" INTEGER);
        CREATE CACHED TABLE "PUBLIC"."CLIENTCERTS"("ID" INTEGER);
        CREATE CACHED TABLE "PUBLIC"."PREFS"("ID" INTEGER);
        INSERT INTO "PUBLIC"."BOOKMARKS" VALUES
        (1, 'Reader''s home', 'gemini://example.com/', 'ROOT', TIMESTAMP '2026-08-31 12:00:00');
        INSERT INTO "PUBLIC"."CLIENTCERTS" VALUES
        (7, 'example.com:1965/private/', U&'CERT\000aLINE', U&'KEY\000aLINE', TRUE, TIMESTAMP '2026-08-31 12:00:00');
        INSERT INTO "PUBLIC"."PREFS" VALUES
        (1, 'home', 'gemini://home.example/', TIMESTAMP '2026-08-31 12:00:00'),
        (2, 'httpproxy', 'proxy.example:1994', TIMESTAMP '2026-08-31 12:00:00');
        """#

        let export = try AlhenaUserDataExport(files: [
            "version.txt": Data("2".utf8),
            "script.sql": Data(script.utf8)
        ])

        XCTAssertEqual(export.version, "2")
        XCTAssertEqual(export.bookmarks, [
            .init(title: "Reader's home", url: URL(string: "gemini://example.com/")!, folder: "ROOT")
        ])
        XCTAssertEqual(export.identities.first?.identifier, "7")
        XCTAssertEqual(export.identities.first?.certificatePEM, "CERT\nLINE")
        XCTAssertEqual(export.identities.first?.privateKeyPEM, "KEY\nLINE")
        XCTAssertEqual(export.identities.first?.url?.absoluteString, "gemini://example.com:1965/private/")
        XCTAssertTrue(export.identities.first?.isActive == true)
        XCTAssertEqual(export.preferences["home"], "gemini://home.example/")
        XCTAssertEqual(export.preferences["httpproxy"], "proxy.example:1994")
    }

    func testRejectsUnknownMajorVersion() {
        XCTAssertThrowsError(try AlhenaUserDataExport(files: [
            "version.txt": Data("3".utf8),
            "script.sql": Data()
        ])) { error in
            XCTAssertEqual(error as? AlhenaUserDataExport.Error, .unsupportedVersion("3"))
        }
    }

    func testRejectsArbitrarySQLArchive() {
        XCTAssertThrowsError(try AlhenaUserDataExport(files: [
            "version.txt": Data("2".utf8),
            "script.sql": Data("SELECT 1;".utf8)
        ])) { error in
            XCTAssertEqual(error as? AlhenaUserDataExport.Error, .invalidDatabase)
        }
    }
}
