import Foundation
import XCTest
@testable import MajorTomCore

@MainActor
final class ServerTrustAuthorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let endpoint = CapsuleEndpoint(host: "example.com")

    func testUnavailableStoreRefusesFirstUseWithoutPrompt() async {
        let authority = ServerTrustAuthority(read: { _ in throw ServerTrustAuthorityError.storeUnavailable }, save: { _, _ in
            XCTFail("Unavailable store cannot accept trust")
        })
        do {
            _ = try await authority.authorize(identity())
            XCTFail("Expected failure")
        } catch ServerTrustAuthorityError.storeUnavailable {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(authority.pendingDecision)
    }

    func testSharedChallengeSurvivesOneRequesterCancelling() async throws {
        let store = try makeStore()
        let presented = identity(expired: true)
        let authority = makeAuthority(store)
        let shown = XCTestExpectation(description: "One shared prompt")
        shown.assertForOverFulfill = true
        authority.decisionChanged = { if $0 != nil { shown.fulfill() } }
        let first = Task { try await authority.authorize(presented) }
        let registered = XCTestExpectation(description: "Second requester entered")
        let second = Task {
            registered.fulfill()
            return try await authority.authorize(presented)
        }
        await wait([shown, registered])
        let decision = try XCTUnwrap(authority.pendingDecision)
        first.cancel()
        do { _ = try await value(first); XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(authority.pendingDecision?.id, decision.id)
        authority.respond(to: decision.id, allow: true)
        let approved = try await value(second)
        XCTAssertTrue(approved)
        let pin = await store.identity(for: endpoint)
        XCTAssertEqual(pin?.publicKeySHA256, presented.publicKeySHA256)
    }

    func testCancellingLastRequesterWithdrawsPromptAndIgnoresLateApproval() async throws {
        let store = try makeStore()
        let authority = makeAuthority(store)
        let shown = XCTestExpectation(description: "Prompt shown")
        authority.decisionChanged = { if $0 != nil { shown.fulfill() } }
        let task = Task { try await authority.authorize(identity(expired: true)) }
        await wait([shown])
        let decision = try XCTUnwrap(authority.pendingDecision)
        task.cancel()
        do { _ = try await value(task); XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertNil(authority.pendingDecision)
        authority.respond(to: decision.id, allow: true)
        let pin = await store.identity(for: endpoint)
        XCTAssertNil(pin)
    }

    func testDateApprovalIsSharedUntilQuitButDifferentCertificateDatesPromptAgain() async throws {
        let store = try makeStore()
        let authority = makeAuthority(store)
        let presented = identity(expired: true)
        let shown = XCTestExpectation(description: "Date warning")
        authority.decisionChanged = { if $0 != nil { shown.fulfill() } }
        let task = Task { try await authority.authorize(presented) }
        await wait([shown])
        authority.respond(to: try XCTUnwrap(authority.pendingDecision).id, allow: true)
        let first = try await value(task)
        XCTAssertTrue(first)
        authority.decisionChanged = { if $0 != nil { XCTFail("Same date warning repeated") } }
        let next = try await authority.authorize(presented)
        XCTAssertTrue(next)

        let newWarning = XCTestExpectation(description: "Changed dates prompt")
        authority.decisionChanged = { if $0 != nil { newWarning.fulfill() } }
        let renewed = PresentedServerIdentity(endpoint: endpoint, publicKeySHA256: presented.publicKeySHA256,
            certificateNotBefore: now.addingTimeInterval(-300), certificateNotAfter: now.addingTimeInterval(-200))
        let changed = Task { try await authority.authorize(renewed) }
        await wait([newWarning])
        authority.respond(to: try XCTUnwrap(authority.pendingDecision).id, allow: false)
        let denied = try await value(changed)
        XCTAssertFalse(denied)

        let restarted = makeAuthority(store)
        let restartWarning = XCTestExpectation(description: "New authority forgets date exception")
        restarted.decisionChanged = { if $0 != nil { restartWarning.fulfill() } }
        let restart = Task { try await restarted.authorize(presented) }
        await wait([restartWarning])
        restarted.respond(to: try XCTUnwrap(restarted.pendingDecision).id, allow: false)
        _ = try await value(restart)
    }

    func testFailedApprovalIsNotReportedSuccessfulOrRemembered() async throws {
        let date = now
        let authority = ServerTrustAuthority(read: { _ in nil }, save: { _, _ in throw CocoaError(.fileWriteNoPermission) }, now: { date })
        for _ in 0..<2 {
            let shown = XCTestExpectation(description: "Failed save prompts again")
            authority.decisionChanged = { if $0 != nil { shown.fulfill() } }
            let task = Task { try await authority.authorize(identity(expired: true)) }
            await wait([shown])
            authority.respond(to: try XCTUnwrap(authority.pendingDecision).id, allow: true)
            do { _ = try await value(task); XCTFail("Failed save authorized connection") } catch let error as CocoaError {
                XCTAssertEqual(error.code, .fileWriteNoPermission)
            }
        }
    }

    func testConcurrentFirstUseOfDifferentKeysCannotBothBeSilentlyTrusted() async throws {
        let store = try makeStore()
        let a = identity()
        let b = identity(key: "b")
        let savingFirst = XCTestExpectation(description: "First pin commit entered")
        let release = AsyncStream<Void>.makeStream()
        let date = now
        let authority = ServerTrustAuthority(read: { await store.identity(for: $0) }, save: { identity, source in
            if identity == a {
                savingFirst.fulfill()
                for await _ in release.stream { break }
            }
            try await store.trust(identity, source: source)
        }, now: { date })
        let changed = XCTestExpectation(description: "Competing key requires approval")
        authority.decisionChanged = { if $0 != nil { changed.fulfill() } }
        let first = Task { try await authority.authorize(a) }
        await wait([savingFirst])
        let enteredSecond = XCTestExpectation(description: "Competing request entered")
        let second = Task {
            enteredSecond.fulfill()
            return try await authority.authorize(b)
        }
        await wait([enteredSecond])
        release.continuation.yield(())
        release.continuation.finish()
        let approved = try await value(first)
        XCTAssertTrue(approved)
        await wait([changed])
        let decision = try XCTUnwrap(authority.pendingDecision)
        guard case .changed(let presented, let previous) = decision.challenge else { return XCTFail("Expected changed-key challenge") }
        XCTAssertEqual(presented.publicKeySHA256, b.publicKeySHA256)
        XCTAssertEqual(previous.publicKeySHA256, a.publicKeySHA256)
        authority.respond(to: decision.id, allow: false)
        let allowed = try await value(second)
        XCTAssertFalse(allowed)
    }

    func testAnswerForWrongPromptCannotAuthorizePendingRequest() async throws {
        let store = try makeStore()
        let authority = makeAuthority(store)
        let shown = XCTestExpectation(description: "Prompt")
        authority.decisionChanged = { if $0 != nil { shown.fulfill() } }
        let task = Task { try await authority.authorize(identity(expired: true)) }
        await wait([shown])
        let id = try XCTUnwrap(authority.pendingDecision).id
        authority.respond(to: UUID(), allow: true)
        XCTAssertEqual(authority.pendingDecision?.id, id)
        authority.respond(to: id, allow: false)
        let allowed = try await value(task)
        XCTAssertFalse(allowed)
    }

    func testSuspensionDrainsAcceptedSaveBeforeTrustCanBeDeleted() async throws {
        let store = try makeStore()
        let firstIdentity = identity()
        let gate = TrustWriteGate()
        defer { Task { await gate.release() } }
        let date = now
        let authority = ServerTrustAuthority(read: { await store.identity(for: $0) }, save: { identity, source in
            if identity == firstIdentity { await gate.wait() }
            // An accepted database transaction need not honor caller cancellation.
            try await Task.detached { try await store.trust(identity, source: source) }.value
        }, now: { date })
        let request = Task { try await authority.authorize(firstIdentity) }
        await wait([gate.entered])
        var didDrain = false
        let drained = XCTestExpectation(description: "Accepted trust write drained")
        let suspension = Task {
            await authority.suspendAndDrain()
            didDrain = true
            drained.fulfill()
        }
        do { _ = try await value(request); XCTFail("Suspension must detach requesters") } catch is CancellationError {}
        XCTAssertFalse(didDrain, "Deletion must wait for the accepted transaction")
        do { _ = try await authority.authorize(identity(key: "b")); XCTFail("Authorization must stay suspended") } catch is CancellationError {}
        await gate.release()
        await wait([drained])
        await suspension.value
        let accepted = await store.identity(for: endpoint)
        XCTAssertEqual(accepted?.publicKeySHA256, firstIdentity.publicKeySHA256)
        try await store.removeAllUserTrust()
        authority.resumeAuthorization()
        let replacement = identity(key: "b")
        let allowed = try await authority.authorize(replacement)
        XCTAssertTrue(allowed)
        let retained = await store.identity(for: endpoint)
        XCTAssertEqual(retained?.publicKeySHA256, replacement.publicKeySHA256)
    }

    func testSuspensionWithdrawsDecisionsAndForgetsDateExceptions() async throws {
        let store = try makeStore()
        let authority = makeAuthority(store)
        let firstShown = XCTestExpectation(description: "Initial date decision")
        authority.decisionChanged = { if $0 != nil { firstShown.fulfill() } }
        let initial = Task { try await authority.authorize(identity(expired: true)) }
        await wait([firstShown])
        let oldID = try XCTUnwrap(authority.pendingDecision).id
        await authority.suspendAndDrain()
        do { _ = try await value(initial); XCTFail("Pending decision must be cancelled") } catch is CancellationError {}
        XCTAssertNil(authority.pendingDecision)
        authority.respond(to: oldID, allow: true)
        authority.resumeAuthorization()
        let shown = XCTestExpectation(description: "Fresh date decision")
        authority.decisionChanged = { if $0 != nil { shown.fulfill() } }
        let next = Task { try await authority.authorize(identity(expired: true)) }
        await wait([shown])
        authority.respond(to: try XCTUnwrap(authority.pendingDecision).id, allow: true)
        let nextAllowed = try await value(next)
        XCTAssertTrue(nextAllowed)
        await authority.suspendAndDrain()
        authority.resumeAuthorization()
        let repeated = XCTestExpectation(description: "Deletion boundary forgot exception")
        authority.decisionChanged = { if $0 != nil { repeated.fulfill() } }
        let afterReset = Task { try await authority.authorize(identity(expired: true)) }
        await wait([repeated])
        authority.respond(to: try XCTUnwrap(authority.pendingDecision).id, allow: false)
        let afterResetAllowed = try await value(afterReset)
        XCTAssertFalse(afterResetAllowed)
    }

    private func value(_ task: Task<Bool, any Error>) async throws -> Bool {
        let finished = XCTestExpectation(description: "Authorization finishes")
        let observer = Task {
            defer { finished.fulfill() }
            return try await task.value
        }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        if result != .completed { task.cancel() }
        XCTAssertEqual(result, .completed)
        return try await observer.value
    }

    private func identity(key: String = "a", expired: Bool = false) -> PresentedServerIdentity {
        PresentedServerIdentity(endpoint: endpoint, publicKeySHA256: String(repeating: key, count: 64),
            certificateNotBefore: now.addingTimeInterval(-300), certificateNotAfter: now.addingTimeInterval(expired ? -100 : 300))
    }
    private func makeStore() throws -> TrustedIdentityStore {
        try TrustedIdentityStore(database: MajorTomDatabase(inMemory: ()))
    }
    private func makeAuthority(_ store: TrustedIdentityStore) -> ServerTrustAuthority {
        let date = now
        return ServerTrustAuthority(read: { await store.identity(for: $0) }, save: { try await store.trust($0, source: $1) }, now: { date })
    }
    private func wait(_ expectations: [XCTestExpectation]) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 3)
        XCTAssertEqual(result, .completed)
    }
}

private actor TrustWriteGate {
    nonisolated let entered = XCTestExpectation(description: "Durable trust write entered")
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        entered.fulfill()
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
