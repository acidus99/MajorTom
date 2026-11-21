import Foundation

/// Writes ordinary CSS, never an app-owned format that needs to be regenerated
/// after editing. Copying changes only the leading metadata's display name.
public enum ContentThemeAuthoring {
    public static func create(
        in directory: URL, name: String, appearance: ContentThemeAppearance,
        copying original: ContentTheme? = nil
    ) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 180,
              !name.contains("*/"), name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw AuthoringError.invalidName
        }
        let original = try original ?? starter(for: appearance)
        var css = original.css
        guard let opening = css.range(of: "/*"),
              let closing = css.range(of: "*/", range: opening.upperBound..<css.endIndex),
              let field = css.range(of: #"(?m)^[\t ]*@name[\t ]+[^\r\n]*"#,
                options: .regularExpression, range: opening.upperBound..<closing.lowerBound) else {
            throw AuthoringError.invalidName
        }
        css.replaceSubrange(field, with: "@name \(name)")
        // Validate before creating a file, including metadata introduced by a name.
        _ = try ContentTheme(id: "custom/new.css", css: css)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = name.map { "/:\\".contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let stem = safeName.isEmpty ? "Theme" : safeName
        let data = Data(css.utf8)
        guard data.count <= 1_048_576 else {
            throw ContentTheme.ThemeError.invalidMetadata("Theme files must be no larger than 1 MB.")
        }
        for number in 1...1_000 {
            let suffix = number == 1 ? "" : " \(number)"
            let url = directory.appendingPathComponent("\(stem)\(suffix).css")
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw AuthoringError.tooManyCopies
    }

    public static func suggestedCopyName(for theme: ContentTheme, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "\(theme.name) modified \(formatter.string(from: date))"
    }

    private static func starter(for appearance: ContentThemeAppearance) throws -> ContentTheme {
        let name = appearance == .light ? "Light" : "Dark"
        guard let url = Bundle.module.url(forResource: name, withExtension: "css", subdirectory: "ThemeTemplates") else {
            throw AuthoringError.missingTemplate
        }
        return try ContentTheme(id: "template:" + name, css: String(contentsOf: url, encoding: .utf8))
    }

    public enum AuthoringError: LocalizedError {
        case invalidName, tooManyCopies, missingTemplate

        public var errorDescription: String? {
            switch self {
            case .invalidName: "Choose a short theme name without line breaks or CSS comment endings (*/)."
            case .tooManyCopies: "There are too many themes with this filename. Choose another name."
            case .missingTemplate: "The custom theme template is missing from the app."
            }
        }
    }
}
