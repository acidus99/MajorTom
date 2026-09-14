import Foundation
import Security

/// Keeps ordinary releases on the historical storage locations while carving developer
/// builds into an isolated local namespace. CloudKit itself already separates its
/// development and production databases; the app must do the same for local state.
enum MajorTomDataScope {
    static let cloudEnvironment: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-environment" as CFString, nil
              ) as? String else { return nil }
        return value.lowercased()
    }()

    static let isProduction = cloudEnvironment == "production"
    static let supportDirectoryName = isProduction ? "Major Tom" : "Major Tom Development"
    static var defaults: UserDefaults {
        guard !isProduction else { return .standard }
        return UserDefaults(suiteName: "dev.gemi.major-tom.development") ?? .standard
    }

    static var keychainNamespace: String? { isProduction ? nil : "development" }

    static func supportFile(named filename: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .appendingPathComponent(filename)
    }
}
