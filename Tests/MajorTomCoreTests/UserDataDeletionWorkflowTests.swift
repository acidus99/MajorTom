import XCTest
@testable import MajorTomCore

final class UserDataDeletionWorkflowTests: XCTestCase {
    @MainActor
    func testDeletionOrdersDurableStepsAndAlwaysFinishes() async throws {
        let probe = DeletionProbe()
        let workflow = UserDataDeletionWorkflow(services: services(probe))
        try await workflow.delete()
        XCTAssertEqual(probe.steps, ["prepare", "identities", "bookmarks", "trust", "homepage", "finish"])
        XCTAssertFalse(workflow.isDeleting)
    }

    @MainActor
    func testPartialFailureReportsCompletedStepsAndDoesNotContinue() async throws {
        let probe = DeletionProbe()
        var dependencies = services(probe)
        dependencies.deleteBookmarks = { probe.steps.append("bookmarks"); throw DeletionFailure.refused }
        let workflow = UserDataDeletionWorkflow(services: dependencies)
        do {
            try await workflow.delete()
            XCTFail("Partial deletion must be reported")
        } catch UserDataDeletionError.failed(stage: .bookmarks, completed: let completed, underlying: let error) {
            XCTAssertEqual(completed, [.clientIdentities])
            XCTAssertTrue(error is DeletionFailure)
        }
        XCTAssertEqual(probe.steps, ["prepare", "identities", "bookmarks", "finish"])
        XCTAssertFalse(workflow.isDeleting)
    }

    @MainActor
    func testAccountSwitchDuringAcceptedOperationNeverDeletesNextAccountsData() async throws {
        let probe = DeletionProbe()
        var dependencies = services(probe)
        dependencies.deleteClientIdentities = {
            probe.steps.append("identities")
            probe.account += 1
        }
        let workflow = UserDataDeletionWorkflow(services: dependencies)
        do {
            try await workflow.delete()
            XCTFail("Changed accounts must stop subsequent stages")
        } catch UserDataDeletionError.failed(stage: .clientIdentities, completed: let completed, underlying: UserDataDeletionError.accountChanged) {
            XCTAssertEqual(completed, [.clientIdentities])
        }
        XCTAssertEqual(probe.steps, ["prepare", "identities", "finish"])
    }

    @MainActor
    func testSuspendedPreparationRejectsDuplicateAndFailureReleasesBoundary() async throws {
        let probe = DeletionProbe()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let entered = expectation(description: "Preparation accepted")
        var dependencies = services(probe)
        dependencies.prepare = {
            probe.steps.append("prepare")
            entered.fulfill()
            for await _ in gate.stream {}
            throw DeletionFailure.refused
        }
        let workflow = UserDataDeletionWorkflow(services: dependencies)
        let deletion = Task { try await workflow.delete() }
        defer { deletion.cancel() }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        XCTAssertTrue(workflow.isDeleting)
        do {
            try await workflow.delete()
            XCTFail("Duplicate deletion must not be accepted")
        } catch UserDataDeletionError.operationInProgress {}
        gate.continuation.finish()
        do { try await deletion.value; XCTFail("Expected preparation failure") }
        catch UserDataDeletionError.failed(stage: .preparation, completed: let completed, underlying: _) {
            XCTAssertTrue(completed.isEmpty)
        }
        XCTAssertFalse(workflow.isDeleting)
        XCTAssertEqual(probe.steps, ["prepare", "finish"])
    }

    @MainActor
    private func services(_ probe: DeletionProbe) -> UserDataDeletionServices {
        UserDataDeletionServices(
            accountToken: { probe.account },
            prepare: { probe.steps.append("prepare") }, finish: { probe.steps.append("finish") },
            deleteClientIdentities: { probe.steps.append("identities") },
            deleteBookmarks: { probe.steps.append("bookmarks") },
            deleteCapsuleTrust: { probe.steps.append("trust") },
            resetHomepage: { probe.steps.append("homepage") }
        )
    }
}

@MainActor
private final class DeletionProbe {
    var steps: [String] = []
    var account: UInt64 = 0
}
private enum DeletionFailure: Error { case refused }
