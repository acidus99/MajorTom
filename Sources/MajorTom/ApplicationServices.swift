import AppKit
import Combine
import MajorTomCore

/// Live construction is centralized here. Feature workflows receive their own
/// dependencies; native scene construction selects these application instances.
@MainActor
enum ApplicationServices {
    nonisolated static let storage = ApplicationStorage(directory:
        MajorTomDataScope.supportFile(named: MajorTomDatabase.filename)?.deletingLastPathComponent())
    nonisolated static let backForwardCache = storage.session.map(BackForwardCacheStore.init(database:))
    nonisolated static let contentCache = storage.content.map { ContentCache(database: $0) }
    nonisolated static let imageLoader = GeminiImageLoader(cache: contentCache)

    static let lifetime = AcceptedLocalWork()
    static let persistenceActivity = LocalPersistenceActivity()
    static let cloud = ICloudSyncStore(defaults: MajorTomDataScope.defaults,
        database: storage.durable, activity: persistenceActivity)
    static let settings = BrowserSettingsStore(defaults: MajorTomDataScope.defaults,
        publishPreferences: { cloud.updatePreferences($0) })
    static let bookmarks = BookmarksModel(store: initialBookmarkStore(), cache: contentCache, activity: persistenceActivity)
    static let certificates = ClientCertificateStore(defaults: MajorTomDataScope.defaults,
        keychain: ClientCertificateKeychain(namespace: MajorTomDataScope.keychainNamespace),
        repository: initialCertificateRepository(), activity: persistenceActivity)
    static let themes = ContentThemeStore(settings: settings, directory: MajorTomDataScope.supportFile(named: "Themes"))
    static let sessionRestoration = SessionRestorationStore(defaults: MajorTomDataScope.defaults,
        repository: storage.session.map(SessionRepository.init(database:)))
    static let history = BrowsingHistoryStore(defaults: MajorTomDataScope.defaults,
        repository: storage.durable.map(BrowsingHistoryRepository.init(database:)))
    static let inputDrafts = GeminiInputDraftStore(repository: storage.durable.map(GeminiInputDraftRepository.init(database:)))
    static let trustPresentation = ServerTrustPresentation(store: storage.trust)
    static let omnibar = OmnibarStore(history: history, bookmarks: bookmarks)
    static let importer = makeImporter()

    private static func makeImporter() -> UserDataImporter {
        UserDataImporter(services: UserDataImportServices(
            accountToken: { certificates.accountToken },
            canImport: { !userDataDeletion.isDeleting },
            certificates: { certificates.certificates },
            associations: { certificates.associations },
            importIdentity: { try await certificates.importIdentity($0) },
            associate: { await certificates.associate(certificateID: $0, with: $1, scope: .pathAndDescendants) },
            importTrust: {
                guard let store = storage.trust else { throw ServerTrustAuthorityError.storeUnavailable }
                return try await store.importTrustedIdentities($0)
            },
            importBookmarks: {
                switch $0 {
                case .lagrange(let value): try await bookmarks.importLagrangeBookmarks(value.bookmarks)
                case .alhena(let value): try await bookmarks.importAlhenaBookmarks(value.bookmarks)
                }
            },
            preferences: { settings.preferences },
            savePreferences: { settings.preferences = $0 }
        ), lifetime: lifetime)
    }
    static let userDataDeletion = makeUserDataDeletion()

    private static func makeUserDataDeletion() -> UserDataDeletionWorkflow {
        UserDataDeletionWorkflow(services: UserDataDeletionServices(
            accountToken: { certificates.accountToken },
            prepare: {
                guard !browsingData.isClearing, !importer.isImporting else {
                    throw BrowsingDataWorkflowError.operationInProgress
                }
                await trustPresentation.suspendAndDrain()
                await browsingData.workflow.cancelAndDrainRequests()
                for browser in NativeTabCoordinator.shared.browsingDataModels {
                    await browser.cancelAndDrainNativeRequests()
                }
            },
            finish: { trustPresentation.resumeAuthorization() },
            deleteClientIdentities: { try await certificates.deleteAll() },
            deleteBookmarks: { try await bookmarks.deleteAll() },
            deleteCapsuleTrust: {
                guard let store = storage.trust else {
                    throw ServerTrustAuthorityError.storeUnavailable
                }
                try await store.removeAllUserTrust()
            },
            resetHomepage: {
                var preferences = settings.preferences
                preferences.homepage = BrowserPreferences().homepage
                settings.preferences = preferences
            }
        ), lifetime: lifetime)
    }

    static let browsingData = BrowsingDataController(workflow: makeBrowsingDataWorkflow())

    private static func makeBrowsingDataWorkflow() -> BrowsingDataWorkflow {
        BrowsingDataWorkflow(services: BrowsingDataServices(
            clearReusableResponses: { cutoff in
                guard let cache = contentCache else { throw BrowsingDataWorkflowError.storageUnavailable }
                try await cache.removeResponses(since: cutoff)
            },
            persistLiveSession: {
                if !NativeTabCoordinator.shared.browsingDataModels.isEmpty {
                    try NativeTabCoordinator.shared.persistSessionAfterClearing()
                }
            },
            clearSavedVisits: { try sessionRestoration.clearBrowsingData($0, since: $1) },
            clearHistory: { try history.clear(since: $0) },
            clearInputDrafts: { try inputDrafts.clear(since: $0) }
        ), lifetime: lifetime)
    }

    private static var observations: Set<AnyCancellable> = []
    private static var hasStarted = false

    private static func initialBookmarkStore() -> BookmarkStore? {
        do {
            if let database = storage.durable {
                let account = try CloudSyncRepository(database: database).activeAccountIdentityHash()
                return try BookmarkStore(database: database, accountIdentityHash: account,
                    legacyFileURL: MajorTomDataScope.supportFile(named: "bookmarks.json"))
            }
            return nil
        } catch { persistenceActivity.report(error); return nil }
    }

    private static func initialCertificateRepository() -> ClientCertificateSyncRepository? {
        guard let database = storage.durable else { return nil }
        do {
            let account = try CloudSyncRepository(database: database).activeAccountIdentityHash()
            return ClientCertificateSyncRepository(database: database, accountIdentityHash: account)
        } catch { persistenceActivity.report(error); return nil }
    }

    static func browser(restoredState: RestoredTabState?, initialURL: URL?) -> BrowserModel {
        let transport = GeminiTransport()
        let cache = contentCache
        let retriever = GeminiResourceRetriever<ClientTLSIdentity>(
            transportEvents: { target, identity, configuration, authorize in
                transport.events(for: target, clientIdentity: identity, configuration: configuration, authorizeTrust: authorize)
            }, cache: cache, resolveIdentity: { url in
                guard let resolved = await certificates.resolvedCertificate(for: url) else { return nil }
                return GeminiRetrievalIdentity(descriptor: resolved.descriptor, credential: resolved.tlsIdentity)
            }, authorizeTrust: { identity, _ in await trustPresentation.authorize(identity) }
        )
        var services = BrowserSessionServices(preferences: { settings.preferences }, retriever: retriever)
        services.preparePresentation = { await themes.waitUntilReady() }
        services.contentStyle = { zoom, hides, inset in
            BrowserModel.contentStyle(themes: themes, preferences: settings.preferences, zoom: zoom, hides: hides, inset: inset)
        }
        services.faviconLoader = GeminiFaviconLoader(cache: cache) { target in try await retriever.response(for: target, purpose: .favicon) }
        services.imageLoader = imageLoader
        services.authorizeTrust = { identity, _ in await trustPresentation.authorize(identity) }
        services.backForwardCache = backForwardCache
        services.recordVisit = { history.record($0, title: $1) }
        services.updateBookmarkFavicon = { bookmarks.updateFavicon($0, for: $1, fetchedAt: $2) }
        services.certificateDescriptor = { certificates.descriptor(id: $0) }
        services.inputDraft = { inputDrafts.text(for: $0) }
        services.saveInputDraft = { inputDrafts.save($0, for: $1) }
        services.removeInputDraft = { inputDrafts.remove(for: $0) }
        services.openExternalURL = { NSWorkspace.shared.open($0) }
        let browser = BrowserModel(services: services, settings: settings, themes: themes,
            clientCertificates: certificates, trustStore: storage.trust, restoredState: restoredState, initialURL: initialURL)
        browsingData.register(browser.session)
        return browser
    }

    static func start() {
        guard !hasStarted else { return }
        hasStarted = true
        _ = bookmarks
        _ = certificates
        cloud.receivedPreferences.sink { settings.apply($0) }.store(in: &observations)
        cloud.receivedAccountPreferences.sink { settings.apply($0, force: true) }.store(in: &observations)
        cloud.receivedBookmarks.sink { Task { await bookmarks.reload() } }.store(in: &observations)
        cloud.receivedClientCertificates.sink { Task { await certificates.reloadCommittedCatalogue() } }.store(in: &observations)
        cloud.activeAccountChanged.sink { account in
            guard let database = storage.durable else { return }
            do { bookmarks.replaceStore(try BookmarkStore(database: database, accountIdentityHash: account)) }
            catch { bookmarks.replaceStore(nil); persistenceActivity.report(error) }
            certificates.replaceRepository(ClientCertificateSyncRepository(database: database, accountIdentityHash: account))
        }.store(in: &observations)
        cloud.prepareForFirstAccountClaim = {
            try await bookmarks.prepareForFirstAccountClaim()
            try await certificates.prepareForFirstAccountClaim()
        }
        cloud.configure(preferences: settings.initialSyncedSnapshot)
        cloud.start()
    }

    @MainActor
    static func presentStorageOpeningFailures() {
        guard !storage.failures.isEmpty else { return }
        let names = storage.failures.map { failure in
            switch failure.store {
            case .durable: "bookmarks, history, and identity metadata"
            case .session: "saved windows and Back/Forward visits"
            case .content: "cached responses"
            case .trust: "trusted capsule identities"
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some Local Storage Is Unavailable"
        alert.informativeText = "Major Tom could not open storage for \(names.joined(separator: "; ")). Changes to affected data may not be saved. Connections requiring unavailable capsule trust will be refused. Quit and try again, or check available disk space and access to application data."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
