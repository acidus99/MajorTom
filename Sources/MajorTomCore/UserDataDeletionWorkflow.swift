import Combine
import Foundation

public enum UserDataDeletionStage: Sendable {
    case preparation, clientIdentities, bookmarks, capsuleTrust, homepage
}

public enum UserDataDeletionError: Error {
    case operationInProgress
    case accountChanged
    case failed(stage: UserDataDeletionStage, completed: [UserDataDeletionStage], underlying: any Error)
}

@MainActor
public struct UserDataDeletionServices {
    public var accountToken: @MainActor () -> UInt64
    public var prepare: @MainActor () async throws -> Void
    public var finish: @MainActor () -> Void
    public var deleteClientIdentities: @MainActor () async throws -> Void
    public var deleteBookmarks: @MainActor () async throws -> Void
    public var deleteCapsuleTrust: @MainActor () async throws -> Void
    public var resetHomepage: @MainActor () throws -> Void

    public init(
        accountToken: @escaping @MainActor () -> UInt64,
        prepare: @escaping @MainActor () async throws -> Void,
        finish: @escaping @MainActor () -> Void,
        deleteClientIdentities: @escaping @MainActor () async throws -> Void,
        deleteBookmarks: @escaping @MainActor () async throws -> Void,
        deleteCapsuleTrust: @escaping @MainActor () async throws -> Void,
        resetHomepage: @escaping @MainActor () throws -> Void
    ) {
        self.accountToken = accountToken
        self.prepare = prepare
        self.finish = finish
        self.deleteClientIdentities = deleteClientIdentities
        self.deleteBookmarks = deleteBookmarks
        self.deleteCapsuleTrust = deleteCapsuleTrust
        self.resetHomepage = resetHomepage
    }
}

/// A confirmed cross-store operation, with explicit partial failure. It never
/// waits for cloud delivery or claims atomicity across SQLite and Keychain.
@MainActor
public final class UserDataDeletionWorkflow: ObservableObject {
    @Published public private(set) var isDeleting = false
    private let lifetime: AcceptedLocalWork
    private let services: UserDataDeletionServices

    public init(services: UserDataDeletionServices, lifetime: AcceptedLocalWork? = nil) {
        self.services = services
        self.lifetime = lifetime ?? AcceptedLocalWork()
    }

    public func delete() async throws {
        try await lifetime.perform { try await self.performConfirmed() }
    }

    private func performConfirmed() async throws {
        guard !isDeleting else { throw UserDataDeletionError.operationInProgress }
        isDeleting = true
        let account = services.accountToken()
        var stage = UserDataDeletionStage.preparation
        var completed: [UserDataDeletionStage] = []
        defer { services.finish(); isDeleting = false }
        func requireAccount() throws {
            guard services.accountToken() == account else { throw UserDataDeletionError.accountChanged }
        }
        do {
            try await services.prepare()
            try requireAccount()
            stage = .clientIdentities
            try await services.deleteClientIdentities()
            completed.append(stage)
            try requireAccount()
            stage = .bookmarks
            try await services.deleteBookmarks()
            completed.append(stage)
            try requireAccount()
            stage = .capsuleTrust
            try await services.deleteCapsuleTrust()
            completed.append(stage)
            try requireAccount()
            stage = .homepage
            try services.resetHomepage()
            completed.append(stage)
        } catch {
            throw UserDataDeletionError.failed(stage: stage, completed: completed, underlying: error)
        }
    }
}
