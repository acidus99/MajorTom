import Combine
import Foundation
import MajorTomCore
import SwiftUI

@MainActor
final class BrowserSettingsStore: ObservableObject {
    static let shared = BrowserSettingsStore()

    /// `@Published` emits from `willSet`, while browser models need to read the fully
    /// updated store when re-rendering. This post-update stream keeps every tab in sync
    /// without making the selected tab a special case.
    let preferencesDidChange = PassthroughSubject<BrowserPreferences, Never>()

    @Published var preferences: BrowserPreferences {
        didSet {
            let changeCameFromICloud = isApplyingRemotePreferences
            let synchronizedValuesChanged = SyncedBrowserPreferenceValues(preferences: oldValue)
                != SyncedBrowserPreferenceValues(preferences: preferences)
            if !changeCameFromICloud, synchronizedValuesChanged {
                modifiedAt = Date()
            }
            persist()
            preferencesDidChange.send(preferences)
            if !changeCameFromICloud, synchronizedValuesChanged {
                scheduleICloudUpload()
            }
        }
    }

    private let defaults: UserDefaults
    private let key = "browser-preferences-v1"
    private let modifiedAtKey = "browser-preferences-modified-at-v1"
    /// Marks the one-time migration that disables automatic same-capsule images for
    /// existing installations, including installations that previously enabled it.
    private let sameCapsuleImageDefaultMigrationKey = "browser-preferences-same-capsule-images-disabled-v1"
    private var modifiedAt: Date
    private var isApplyingRemotePreferences = false
    private var iCloudObserver: AnyCancellable?
    private var uploadTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedData = defaults.data(forKey: key)
        var loadedPreferences: BrowserPreferences
        var loadedModifiedAt: Date
        if let data = storedData,
           let decoded = try? JSONDecoder().decode(BrowserPreferences.self, from: data) {
            loadedPreferences = decoded
            loadedModifiedAt = defaults.object(forKey: modifiedAtKey) as? Date ?? Date()
        } else {
            loadedPreferences = BrowserPreferences()
            loadedModifiedAt = .distantPast
        }

        let needsSameCapsuleImageMigration = !defaults.bool(forKey: sameCapsuleImageDefaultMigrationKey)
        if needsSameCapsuleImageMigration {
            loadedPreferences.automaticallyLoadsSameCapsuleImages = false
            loadedModifiedAt = Date()
            defaults.set(true, forKey: sameCapsuleImageDefaultMigrationKey)
        }
        preferences = loadedPreferences
        modifiedAt = loadedModifiedAt

        if needsSameCapsuleImageMigration, storedData != nil {
            persist()
        }

        iCloudObserver = ICloudSyncStore.shared.receivedPreferences.sink { [weak self] snapshot in
            self?.apply(snapshot)
        }
        let localSnapshot = storedData == nil ? nil : SyncedBrowserPreferences(
            preferences: preferences,
            modifiedAt: modifiedAt
        )
        ICloudSyncStore.shared.configure(preferences: localSnapshot)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
        defaults.set(modifiedAt, forKey: modifiedAtKey)
    }

    private func scheduleICloudUpload() {
        uploadTask?.cancel()
        let snapshot = SyncedBrowserPreferences(preferences: preferences, modifiedAt: modifiedAt)
        uploadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            ICloudSyncStore.shared.updatePreferences(snapshot)
        }
    }

    private func apply(_ snapshot: SyncedBrowserPreferences) {
        let local = SyncedBrowserPreferences(preferences: preferences, modifiedAt: modifiedAt)
        guard snapshot.shouldReplace(local) else { return }
        uploadTask?.cancel()
        modifiedAt = snapshot.modifiedAt
        isApplyingRemotePreferences = true
        // Proxy, application appearance, and Favorites-bar visibility belong to this
        // Mac. Only overlay the durable reading and navigation preferences from iCloud.
        preferences = snapshot.applying(to: preferences)
        isApplyingRemotePreferences = false
    }

    func binding<Value>(_ keyPath: WritableKeyPath<BrowserPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { value in
                var updated = self.preferences
                updated[keyPath: keyPath] = value
                self.preferences = updated
            }
        )
    }
}
