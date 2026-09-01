import Foundation
import XCTest
@testable import MajorTomCore

final class CloudSyncModelTests: XCTestCase {
    func testPagedCloudResultsKeepNewestDuplicateWithoutTrapping() {
        struct Value: Equatable {
            var id: String
            var modifiedAt: Date?
            var payload: String
        }
        let older = Value(
            id: "duplicate",
            modifiedAt: Date(timeIntervalSince1970: 10),
            payload: "older"
        )
        let unrelated = Value(
            id: "other",
            modifiedAt: Date(timeIntervalSince1970: 15),
            payload: "other"
        )
        let newer = Value(
            id: "duplicate",
            modifiedAt: Date(timeIntervalSince1970: 20),
            payload: "newer"
        )

        let coalesced = newestValuesByID(
            [older, unrelated, newer],
            id: \.id,
            modifiedAt: \.modifiedAt
        )

        XCTAssertEqual(coalesced.count, 2)
        XCTAssertEqual(coalesced["duplicate"], newer)
        XCTAssertEqual(coalesced["other"], unrelated)
    }

    func testNewerPreferencesReplaceOlderPreferences() {
        let old = SyncedBrowserPreferences(
            preferences: BrowserPreferences(homepage: "gemini://old.example/"),
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let new = SyncedBrowserPreferences(
            preferences: BrowserPreferences(homepage: "gemini://new.example/"),
            modifiedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertTrue(new.shouldReplace(old))
        XCTAssertFalse(old.shouldReplace(new))
        XCTAssertFalse(old.shouldReplace(old))
        XCTAssertTrue(old.shouldReplace(nil))
    }

    func testVisibleCloudTabsExcludeThisDeviceEmptyAndStaleSnapshots() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let localID = UUID()
        let recentID = UUID()
        let page = CloudTabSnapshot(
            id: UUID(),
            title: "Capsule",
            url: URL(string: "gemini://example.com/")!
        )
        let snapshots = [
            CloudTabDeviceSnapshot(
                deviceID: localID,
                deviceName: "This Mac",
                updatedAt: now,
                tabs: [page]
            ),
            CloudTabDeviceSnapshot(
                deviceID: recentID,
                deviceName: "Other Mac",
                updatedAt: now.addingTimeInterval(-60),
                tabs: [page]
            ),
            CloudTabDeviceSnapshot(
                deviceID: UUID(),
                deviceName: "No Tabs",
                updatedAt: now,
                tabs: []
            ),
            CloudTabDeviceSnapshot(
                deviceID: UUID(),
                deviceName: "Old Mac",
                updatedAt: now.addingTimeInterval(-1_000),
                tabs: [page]
            )
        ]

        let visible = snapshots.visibleCloudTabDevices(
            excluding: localID,
            at: now,
            maximumAge: 300
        )

        XCTAssertEqual(visible.map(\.deviceID), [recentID])
    }

    func testCloudTabPayloadRoundTrips() throws {
        let original = CloudTabDeviceSnapshot(
            deviceID: UUID(),
            deviceName: "Studio",
            updatedAt: Date(timeIntervalSince1970: 42),
            tabs: [CloudTabSnapshot(
                id: UUID(),
                title: "Gemini",
                url: URL(string: "gemini://geminiprotocol.net/")!
            )]
        )

        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(CloudTabDeviceSnapshot.self, from: data), original)
    }

    func testNewerClientCertificateMetadataReplacesOlderMetadata() {
        let old = SyncedClientCertificates(modifiedAt: Date(timeIntervalSince1970: 10))
        let new = SyncedClientCertificates(modifiedAt: Date(timeIntervalSince1970: 20))

        XCTAssertTrue(new.shouldReplace(old))
        XCTAssertFalse(old.shouldReplace(new))
        XCTAssertFalse(old.shouldReplace(old))
        XCTAssertTrue(old.shouldReplace(nil))
    }

    func testSyncedPreferencesDoNotReplaceMachineLocalChoices() {
        let remote = SyncedBrowserPreferences(
            preferences: BrowserPreferences(
                homepage: "gemini://remote.example/",
                applicationAppearance: .dark,
                proxy: GeminiProxyConfiguration(host: "remote-proxy", port: 1_994),
                showsFavoritesBar: false
            ),
            modifiedAt: Date()
        )
        let local = BrowserPreferences(
            homepage: "gemini://local.example/",
            applicationAppearance: .light,
            proxy: GeminiProxyConfiguration(host: "localhost", port: 1_965),
            showsFavoritesBar: true
        )

        let applied = remote.applying(to: local)

        XCTAssertEqual(applied.homepage, "gemini://remote.example/")
        XCTAssertEqual(applied.applicationAppearance, .light)
        XCTAssertEqual(applied.proxy, GeminiProxyConfiguration(host: "localhost", port: 1_965))
        XCTAssertTrue(applied.showsFavoritesBar)
    }

    func testLegacyPreferencePayloadMigratesOnlySynchronizedValues() throws {
        struct LegacyPayload: Codable {
            var preferences: BrowserPreferences
            var modifiedAt: Date
        }
        let legacy = LegacyPayload(
            preferences: BrowserPreferences(
                homepage: "gemini://legacy.example/",
                proxy: GeminiProxyConfiguration(host: "legacy-proxy", port: 1_994)
            ),
            modifiedAt: Date(timeIntervalSince1970: 42)
        )
        let decoded = try JSONDecoder().decode(
            SyncedBrowserPreferences.self,
            from: JSONEncoder().encode(legacy)
        )
        let local = BrowserPreferences(
            proxy: GeminiProxyConfiguration(host: "this-mac", port: 1_965)
        )

        let applied = decoded.applying(to: local)
        XCTAssertEqual(applied.homepage, "gemini://legacy.example/")
        XCTAssertEqual(applied.proxy?.host, "this-mac")
    }

    func testBookmarkTombstoneWinsOverAnOlderOfflineCopy() {
        var collection = BookmarkCollection()
        let bookmark = collection.add(
            title: "Saved",
            url: URL(string: "gemini://example.com/saved")!
        )
        let original = SyncedBookmarks(
            collection: collection,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        collection.remove(bookmarkWith: bookmark.id)
        let deleted = original.reconciled(
            with: collection,
            at: Date(timeIntervalSince1970: 20)
        )

        let merged = original.merging(deleted)

        XCTAssertFalse(merged.collection.contains(url: bookmark.url))
        XCTAssertNotNil(merged.bookmarks.first { $0.id == bookmark.id }?.deletedAt)
    }

    func testBookmarkRecordsMergeIndependentChanges() {
        var firstCollection = BookmarkCollection()
        firstCollection.add(title: "One", url: URL(string: "gemini://one.example/")!)
        var secondCollection = BookmarkCollection(folders: firstCollection.folders)
        secondCollection.add(title: "Two", url: URL(string: "gemini://two.example/")!)
        let first = SyncedBookmarks(
            collection: firstCollection,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let second = first.reconciled(
            with: secondCollection,
            at: Date(timeIntervalSince1970: 20)
        )

        let merged = first.merging(second)

        XCTAssertEqual(Set(merged.collection.allBookmarks.map(\.title)), ["One", "Two"])
    }

    func testBookmarkMergeIsStableWhenCloudRecordOrderChanges() {
        var collection = BookmarkCollection()
        collection.add(title: "One", url: URL(string: "gemini://one.example/")!)
        collection.add(title: "Two", url: URL(string: "gemini://two.example/")!)
        let state = SyncedBookmarks(collection: collection, modifiedAt: Date())
        let reordered = SyncedBookmarks(
            folders: state.folders.reversed(),
            bookmarks: state.bookmarks.reversed()
        )

        XCTAssertEqual(state.merging(state), state.merging(reordered))
    }

    func testBookmarkReconciliationUsesTheSameCanonicalOrderAsCloudMerge() {
        let activeID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let deletedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSince1970: 10)
        let state = SyncedBookmarks(folders: [
            SyncedBookmarkFolder(
                id: activeID,
                name: BookmarkCollection.favoritesName,
                order: 0,
                modifiedAt: date
            ),
            SyncedBookmarkFolder(
                id: deletedID,
                name: "Deleted",
                order: 1,
                modifiedAt: date,
                deletedAt: date
            ),
        ])

        let reconciled = state.reconciled(with: state.collection, at: date)

        XCTAssertEqual(reconciled, reconciled.merging(reconciled))
        XCTAssertEqual(reconciled.folders.map(\.id), [deletedID, activeID])
    }

    func testFirstCloudMergeDoesNotCreateTwoFavoritesFolders() {
        let local = SyncedBookmarks(
            collection: BookmarkCollection(),
            modifiedAt: Date(timeIntervalSince1970: 20)
        )
        let remote = SyncedBookmarks(
            collection: BookmarkCollection(),
            modifiedAt: Date(timeIntervalSince1970: 10)
        )

        let merged = local.merging(remote)
        let collection = merged.collection

        XCTAssertEqual(
            collection.folders.filter { $0.name == BookmarkCollection.favoritesName }.count,
            1
        )
        let reconciled = merged.reconciled(
            with: collection,
            at: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(reconciled.folders.filter { $0.deletedAt == nil }.count, 1)
    }

    func testCertificateAssociationDeletionCannotBeResurrected() {
        let certificateID = UUID()
        let descriptor = ClientCertificateDescriptor(
            id: certificateID,
            commonName: "Identity",
            notBefore: .distantPast,
            notAfter: .distantFuture,
            certificateSHA256: String(repeating: "a", count: 64),
            publicKeySHA256: String(repeating: "b", count: 64),
            synchronizesWithICloud: false
        )
        let association = ClientCertificateAssociation.entireCapsule(
            certificateID: certificateID,
            endpoint: CapsuleEndpoint(host: "example.com", port: 1_965)
        )
        let original = ClientCertificateSyncState().reconciled(
            certificates: [descriptor],
            associations: [association],
            at: Date(timeIntervalSince1970: 10)
        )
        let deleted = original.reconciled(
            certificates: [descriptor],
            associations: [],
            at: Date(timeIntervalSince1970: 20)
        )

        let merged = original.merging(deleted)

        XCTAssertTrue(merged.activeAssociations.isEmpty)
        XCTAssertFalse(
            merged.activeCertificates(preservingLocalStorageFrom: [descriptor])[0]
                .synchronizesWithICloud
        )
    }

    func testDifferentActiveTrustKeysBecomeAConflict() {
        let endpoint = CapsuleEndpoint(host: "example.com", port: 1_965)
        let first = SyncedServerTrust(decisions: [SyncedServerTrustDecision(
            endpoint: endpoint,
            publicKeySHA256: String(repeating: "a", count: 64),
            firstTrustedAt: Date(timeIntervalSince1970: 10),
            modifiedAt: Date(timeIntervalSince1970: 10)
        )])
        let second = SyncedServerTrust(decisions: [SyncedServerTrustDecision(
            endpoint: endpoint,
            publicKeySHA256: String(repeating: "b", count: 64),
            firstTrustedAt: Date(timeIntervalSince1970: 20),
            modifiedAt: Date(timeIntervalSince1970: 20)
        )])

        XCTAssertEqual(first.merging(second).conflictingEndpoints, [endpoint])
    }

    func testServerTrustMergeIsStableWhenCloudRecordOrderChanges() {
        let decisions = ["one.example", "two.example"].map { host in
            SyncedServerTrustDecision(
                endpoint: CapsuleEndpoint(host: host, port: 1_965),
                publicKeySHA256: String(repeating: host.first!, count: 64),
                firstTrustedAt: Date(timeIntervalSince1970: 10),
                modifiedAt: Date(timeIntervalSince1970: 10)
            )
        }
        let state = SyncedServerTrust(decisions: decisions)
        let reordered = SyncedServerTrust(decisions: decisions.reversed())

        XCTAssertEqual(state.merging(state), state.merging(reordered))
    }
}
