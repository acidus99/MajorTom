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

    public var isCustom: Bool { id.hasPrefix("custom:") }
    public var label: String { "\(name) (\(appearance.label))" }

    public init(id: String, css: String) throws {
        // Only the leading CSS comment is metadata. A capsule-like @name in a CSS
        // string, declaration, or later comment must never change the catalog entry.
        let source = css.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard source.hasPrefix("/*"), let end = source.range(of: "*/") else {
            throw ThemeError.invalidMetadata("A theme must start with a CSS comment containing @name and @appearance.")
        }
        var fields: [String: String] = [:]
        for line in source[source.index(source.startIndex, offsetBy: 2)..<end.lowerBound].split(whereSeparator: \.isNewline) {
            let field = line.trimmingCharacters(in: .whitespaces)
            guard field.hasPrefix("@") else { continue }
            let parts = field.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fields[key] == nil else {
                throw ThemeError.invalidMetadata("Duplicate @\(key) field.")
            }
            fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["name"], !name.isEmpty,
              let value = fields["appearance"],
              let appearance = ContentThemeAppearance(rawValue: value) else {
            throw ThemeError.invalidMetadata("A theme needs @name and @appearance light, dark, or both.")
        }
        self.id = id
        self.name = name
        self.appearance = appearance
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

    public static let bundled: [ContentTheme] = {
        let ids = ["draculaLight", "draculaDark", "draculaClassic", "ocean", "forest", "creamsicle", "sandDunes"]
        return ids.map { id in
            guard let url = Bundle.module.url(forResource: id, withExtension: "css", subdirectory: "Themes"),
                  let css = try? String(contentsOf: url, encoding: .utf8),
                  let theme = try? ContentTheme(id: id, css: css) else {
                preconditionFailure("Missing or invalid bundled theme: \(id)")
            }
            return theme
        }
    }()

    /// A missing custom file never rewrites the saved choice, so restoring that file
    /// restores the selection automatically. An incompatible theme uses the same fallback.
    public static func selected(
        in themes: [ContentTheme], preferences: BrowserPreferences, systemIsDark: Bool
    ) -> (theme: ContentTheme, appearance: ContentThemeAppearance) {
        let appearance = preferences.contentAppearance.resolved(systemIsDark: systemIsDark)
        let id = appearance == .dark ? preferences.darkContentTheme : preferences.lightContentTheme
        let theme = themes.first { $0.id == id && $0.appearance.supports(appearance) }
            ?? bundled.first { $0.id == (appearance == .dark ? "draculaDark" : "draculaLight") }!
        return (theme, appearance)
    }

    public static func loadCustomThemes(in directory: URL) throws -> (themes: [ContentTheme], errors: [String]) {
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
                themes.append(try ContentTheme(id: "custom:" + file.lastPathComponent, css: css))
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
