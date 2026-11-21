import Foundation

public enum ContentAppearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    public func resolved(systemIsDark: Bool) -> ContentThemeAppearance {
        switch self {
        case .system: systemIsDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum ContentThemeAppearance: String, Codable, Sendable {
    case light, dark, both

    public var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .both: "Light and Dark"
        }
    }

    public func supports(_ appearance: Self) -> Bool {
        self == .both || self == appearance
    }
}

/// Theme CSS and metadata are data. WebKit, not a second CSS parser in Core,
/// resolves the cascade and the colors needed by the native presentation.
public struct ContentTheme: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let appearance: ContentThemeAppearance
    public let css: String
    public let metadata: [String: String]

    public var family: String? {
        guard let value = metadata["family"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    public var isCustom: Bool { id.hasPrefix("custom/") }
    public var label: String {
        appearance == .both ? name : "\(name) (\(appearance.label))"
    }

    /// Source metadata opens only ordinary web pages through the user's browser.
    public var sourceURL: URL? {
        guard let source = metadata["source"], let url = URL(string: source),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// A single-appearance theme keeps its own native controls even when selected
    /// for the opposite slot. Dual-appearance files follow the requested slot.
    public func renderingAppearance(for slot: ContentThemeAppearance) -> ContentThemeAppearance {
        appearance == .both ? slot : appearance
    }

    public init(id: String, css: String) throws {
        // Only the leading CSS comment is metadata. A capsule-like @name in a CSS
        // string, declaration, or later comment must never change the catalog entry.
        let source = css.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard source.hasPrefix("/*"), let end = source.range(of: "*/") else {
            throw ThemeError.invalidMetadata("A theme must start with a CSS comment containing @name.")
        }
        var fields: [String: String] = [:]
        for line in source[source.index(source.startIndex, offsetBy: 2)..<end.lowerBound].split(whereSeparator: \.isNewline) {
            var field = line.trimmingCharacters(in: .whitespaces)
            // Accept the colon spelling too, while authoring resources use @family Name.
            if field.hasPrefix("@family:") { field = "@family " + field.dropFirst("@family:".count) }
            guard field.hasPrefix("@") else { continue }
            let parts = field.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fields[key] == nil else {
                throw ThemeError.invalidMetadata("Duplicate @\(key) field.")
            }
            fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["name"], !name.isEmpty else {
            throw ThemeError.invalidMetadata("A theme needs @name.")
        }
        self.id = id
        self.name = name
        self.appearance = fields["appearance"].flatMap { ContentThemeAppearance(rawValue: $0.lowercased()) } ?? .both
        self.css = css
        self.metadata = fields
    }

    public func stylesheet(for appearance: ContentThemeAppearance) -> String {
        ContentThemeStylesheets.base
            + """

            /* Native document controls match the content appearance selected by the app. */
            :root {
              color-scheme: \(appearance.rawValue);
            }

            """
            + css + "\n" + ContentThemeStylesheets.print
    }

    public static let defaultLightIdentifier = "system/alucardClassic.css"
    public static let defaultDarkIdentifier = "system/draculaClassic.css"

    public static var bundledDirectory: URL {
        (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Themes", isDirectory: true)
    }

    /// The catalog follows the resource directory, without a separate list of theme names.
    public static var bundled: [ContentTheme] {
        (try? loadBundledThemes(in: bundledDirectory).themes) ?? []
    }

    /// No theme files remain: use the base stylesheet's native system colors.
    /// This is not a catalog entry or a saved file reference.
    private static let systemColors = try! ContentTheme(id: "", css: "/*\n@name System Colors\n*/")

    public static func fallback(in themes: [ContentTheme], for slot: ContentThemeAppearance) -> ContentTheme {
        let preferred = slot == .dark ? defaultDarkIdentifier : defaultLightIdentifier
        let sorted = themes.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return themes.first { $0.id == preferred }
            ?? sorted.first { !$0.isCustom }
            ?? sorted.first
            ?? systemColors
    }

    public static func selected(
        in themes: [ContentTheme], preferences: BrowserPreferences, systemIsDark: Bool
    ) -> (theme: ContentTheme, appearance: ContentThemeAppearance) {
        let appearance = preferences.contentAppearance.resolved(systemIsDark: systemIsDark)
        let family = preferences.contentThemeSelection == .family
            ? ContentThemeFamily.selected(in: themes, saved: preferences.contentThemeFamily) : nil
        let individual = appearance == .dark ? preferences.darkContentTheme : preferences.lightContentTheme
        let id = family.map { appearance == .dark ? $0.darkTheme : $0.lightTheme } ?? currentIdentifier(individual)
        let theme = themes.first { $0.id == id } ?? fallback(in: themes, for: appearance)
        return (theme, theme.renderingAppearance(for: appearance))
    }

    /// Upgrade previously saved identifiers once; new selections always use source/filename.
    static func currentIdentifier(_ identifier: String) -> String {
        if identifier.isEmpty || identifier.hasPrefix("system/") || identifier.hasPrefix("custom/") {
            return identifier
        }
        if identifier.hasPrefix("custom:") {
            return "custom/" + identifier.dropFirst("custom:".count)
        }
        switch identifier {
        case "draculaDark": return defaultDarkIdentifier
        case "draculaLight": return defaultLightIdentifier
        default: return "system/" + identifier + ".css"
        }
    }

    public static func loadBundledThemes(in directory: URL) throws -> (themes: [ContentTheme], errors: [String]) {
        try loadThemes(in: directory, prefix: "system/")
    }

    public static func loadCustomThemes(in directory: URL) throws -> (themes: [ContentTheme], errors: [String]) {
        try loadThemes(in: directory, prefix: "custom/")
    }

    private static func loadThemes(in directory: URL, prefix: String) throws -> (themes: [ContentTheme], errors: [String]) {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "css" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var themes: [ContentTheme] = []
        var errors: [String] = []
        for file in files {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard let size = values.fileSize, size <= 1_048_576 else {
                    throw ThemeError.invalidMetadata("Theme files must be no larger than 1 MB.")
                }
                let css = try String(contentsOf: file, encoding: .utf8)
                themes.append(try ContentTheme(id: prefix + file.lastPathComponent, css: css))
            } catch {
                errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (themes, errors)
    }

    public enum ThemeError: LocalizedError {
        case invalidMetadata(String)
        public var errorDescription: String? {
            switch self { case .invalidMetadata(let message): message }
        }
    }
}

public enum ContentThemeStylesheets {
    public static let base = load("Base")
    public static let print = load("Print")

    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing stylesheet: \(name).css")
        }
        return css
    }
}
