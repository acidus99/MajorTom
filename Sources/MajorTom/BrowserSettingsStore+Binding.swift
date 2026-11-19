import MajorTomCore
import SwiftUI

extension BrowserSettingsStore {
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
