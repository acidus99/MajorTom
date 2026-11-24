import Foundation

/// Bundle metadata stamped when packaging an app. Release versions come from
/// GitHub; each development or production package advances its own build counter.
/// Unbundled `swift run` executions report local development without a build number.
public enum AppVersion {
    /// Apple's three-part release version. Development bundles use `0.0.0`.
    public static var short: String { infoValue("CFBundleShortVersionString") ?? "0.0.0" }

    public static var build: String { infoValue("CFBundleVersion") ?? "0" }

    /// Build number, actual packaging time, source commit, branch, and modified state.
    public static var buildInfo: String { infoValue("MTBuildInfo") ?? "local development build" }

    public static var isDevelopment: Bool { infoValue("MTBuildChannel") != "production" }

    /// The primary About label. Production build numbers remain in diagnostics.
    public static var label: String {
        label(shortVersion: short, buildNumber: build, development: isDevelopment)
    }

    public static var displayString: String { "\(label) · \(buildInfo)" }

    static func label(shortVersion: String, buildNumber: String, development: Bool) -> String {
        if development {
            return buildNumber == "0" ? "Local Development Build" : "Development Build \(buildNumber)"
        }
        let parts = shortVersion.split(separator: ".")
        let version = parts.count == 3 && parts[2] == "0"
            ? parts.prefix(2).joined(separator: ".") : shortVersion
        return "Version \(version)"
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
