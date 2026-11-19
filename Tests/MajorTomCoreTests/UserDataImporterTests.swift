import XCTest
@testable import MajorTomCore

final class UserDataImporterTests: XCTestCase {
    @MainActor
    func testValidatedLagrangeDataAppliesInOrderAndKeepsUnrelatedPreferences() async throws {
        let probe = ImportProbe()
        probe.preferences.showsFavicons = false
        let importer = UserDataImporter(services: services(probe))
        try await importer.importExport(export())
        XCTAssertEqual(probe.steps, ["trust", "bookmarks", "preferences"])
        XCTAssertEqual(probe.preferences.homepage, "gemini://example.invalid/home")
        XCTAssertFalse(probe.preferences.showsFavicons)
        XCTAssertEqual(importer.resultItems?.count, 3)
        XCTAssertFalse(importer.isImporting)
    }

    @MainActor
    func testTrustFailureDoesNotClaimSuccessOrContinueIntoBookmarksAndPreferences() async throws {
        let probe = ImportProbe()
        var dependencies = services(probe)
        dependencies.importTrust = { _ in probe.steps.append("trust"); throw ImportFailure.refused }
        let importer = UserDataImporter(services: dependencies)
        do { try await importer.importExport(export()); XCTFail("Expected storage failure") }
        catch ImportFailure.refused {}
        XCTAssertEqual(probe.steps, ["trust"])
        XCTAssertNil(importer.resultItems)
        XCTAssertFalse(importer.isImporting)
    }

    @MainActor
    func testAccountSwitchAfterAcceptedWriteStopsBeforeNextDataset() async throws {
        let probe = ImportProbe()
        var dependencies = services(probe)
        dependencies.importTrust = { _ in probe.steps.append("trust"); probe.account += 1; return 1 }
        let importer = UserDataImporter(services: dependencies)
        do { try await importer.importExport(export()); XCTFail("Expected account fence") }
        catch UserDataImportError.accountChanged {}
        XCTAssertEqual(probe.steps, ["trust"])
        XCTAssertNil(importer.resultItems)
    }

    @MainActor
    func testShutdownDrainsAcceptedImportAndRejectsNewOperations() async throws {
        let probe = ImportProbe()
        let lifetime = AcceptedLocalWork()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let entered = expectation(description: "Accepted bookmark write")
        var dependencies = services(probe)
        dependencies.importBookmarks = { _ in
            probe.steps.append("bookmarks")
            entered.fulfill()
            for await _ in gate.stream {}
            return 1
        }
        let importer = UserDataImporter(services: dependencies, lifetime: lifetime)
        let importing = Task { try await importer.importExport(export()) }
        defer { importing.cancel() }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        var drained = false
        let closingStarted = expectation(description: "Shutdown started")
        let closing = Task {
            closingStarted.fulfill()
            await lifetime.closeAndDrain()
            drained = true
        }
        _ = await XCTWaiter.fulfillment(of: [closingStarted], timeout: 2)
        XCTAssertTrue(lifetime.isClosing)
        XCTAssertFalse(drained, "Accepted local work must finish before stores close")
        do { try await lifetime.perform { XCTFail("New work must not start") }; XCTFail("Expected rejection") }
        catch is CancellationError {}
        gate.continuation.finish()
        try await importing.value
        await closing.value
        XCTAssertTrue(drained)
        XCTAssertEqual(probe.steps, ["trust", "bookmarks", "preferences"])
    }

    private func export() throws -> ParsedUserDataExport {
        .lagrange(try LagrangeUserDataExport(files: [
            "lagrange-export.ini": Data("version = \"1.20\"".utf8),
            "bookmarks.ini": Data("[1]\nurl = \"gemini://example.invalid/home\"\ntitle = \"Home\"\ntags = \".homepage\"".utf8),
            "trusted.txt": Data("example.invalid;1965 1 \(String(repeating: "a", count: 64))".utf8)
        ]))
    }

    @MainActor
    private func services(_ probe: ImportProbe) -> UserDataImportServices {
        UserDataImportServices(accountToken: { probe.account }, canImport: { true },
            certificates: { [] }, associations: { [] },
            importIdentity: { _ in XCTFail("Fixture has no identities"); throw ImportFailure.refused },
            associate: { _, _ in XCTFail("Fixture has no assignments"); return false },
            importTrust: { values in probe.steps.append("trust"); return values.count },
            importBookmarks: { _ in probe.steps.append("bookmarks"); return 1 },
            preferences: { probe.preferences },
            savePreferences: { probe.steps.append("preferences"); probe.preferences = $0 })
    }
}

@MainActor
private final class ImportProbe {
    var account: UInt64 = 0
    var preferences = BrowserPreferences()
    var steps: [String] = []
}
private enum ImportFailure: Error { case refused }
