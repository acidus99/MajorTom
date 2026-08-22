import Foundation
import XCTest
@testable import MajorTomCore

final class CloudSyncModelTests: XCTestCase {
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
}
