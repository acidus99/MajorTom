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
            if !changeCameFromICloud {
                modifiedAt = Date()
            }
            persist()
            preferencesDidChange.send(preferences)
            if !changeCameFromICloud {
                scheduleICloudUpload()
            }
        }
    }

    private let defaults: UserDefaults
    private let key = "browser-preferences-v1"
    private let modifiedAtKey = "browser-preferences-modified-at-v1"
    private var modifiedAt: Date
    private var isApplyingRemotePreferences = false
    private var iCloudObserver: AnyCancellable?
    private var uploadTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedData = defaults.data(forKey: key)
        if let data = storedData,
           let decoded = try? JSONDecoder().decode(BrowserPreferences.self, from: data) {
            preferences = decoded
            modifiedAt = defaults.object(forKey: modifiedAtKey) as? Date ?? Date()
        } else {
            preferences = BrowserPreferences()
            modifiedAt = .distantPast
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
        preferences = snapshot.preferences
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
