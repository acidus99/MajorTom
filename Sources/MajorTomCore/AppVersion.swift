import Foundation

/// Major Tom's version.
///
/// The scheme follows Kennedy's: the build is identified by the **date of the commit it
/// was built from**, plus the short commit hash and branch, rather than by a
/// hand-maintained semantic version. Nobody has to remember to bump anything, every
/// build is traceable to an exact commit, and the user-visible number is a date they can
/// reason about ("is my copy newer than the one from last week?").
///
/// Three values are stamped into `Info.plist` by `Scripts/build-app.sh`:
///
/// - `CFBundleShortVersionString` — `2026.8.2`, the commit date. This is what the Finder
///   and the About panel show. macOS requires dot-separated integers, so no leading
///   zeros.
/// - `CFBundleVersion` — `git rev-list --count HEAD`, a monotonically increasing build
///   number. macOS requires this to increase between builds of the same version, and
///   commit count satisfies that automatically.
/// - `MTBuildInfo` — `2026/08/02 - a1b2c3d - main`, the full Kennedy-style string, for
///   diagnostics and bug reports.
///
/// Running via `swift run` produces no bundle, so every accessor falls back rather than
/// reporting something false.
public enum AppVersion {
    /// Commit date as a marketing version, e.g. `2026.8.2`.
    public static var short: String { infoValue("CFBundleShortVersionString") ?? "0.0.0" }

    /// Monotonic build number, e.g. `184`.
    public static var build: String { infoValue("CFBundleVersion") ?? "0" }

    /// Full build identity, e.g. `2026/08/02 - a1b2c3d - main`.
    public static var buildInfo: String { infoValue("MTBuildInfo") ?? "local development build" }

    /// One line suitable for an About panel or a diagnostics page.
    public static var displayString: String {
        "Version \(short) (\(build)) · \(buildInfo)"
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject an unstamped placeholder rather than showing it to the user.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
