import AppKit

/// Provides the small Launch Services bridge needed to make Major Tom handle Gemini URLs.
@available(macOS 26.0, *)
@MainActor
public enum GeminiDefaultApplication {
    public static let scheme = "gemini"

    public static var isMajorTomDefault: Bool {
        guard let sampleURL = URL(string: "\(scheme)://example.invalid/"),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: sampleURL),
              let applicationBundle = Bundle(url: applicationURL),
              let majorTomBundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        return applicationBundle.bundleIdentifier == majorTomBundleIdentifier
    }

    public static func makeMajorTomDefault(
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: scheme,
            completion: completion
        )
    }
}
