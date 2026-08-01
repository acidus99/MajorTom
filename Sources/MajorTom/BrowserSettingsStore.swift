import Combine
import Foundation
import MajorTomCore
import SwiftUI

@MainActor
final class BrowserSettingsStore: ObservableObject {
    static let shared = BrowserSettingsStore()

    @Published var preferences: BrowserPreferences {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key = "browser-preferences-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(BrowserPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = BrowserPreferences()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
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
