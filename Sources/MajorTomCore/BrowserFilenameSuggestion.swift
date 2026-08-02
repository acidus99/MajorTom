import Foundation

public enum BrowserFilenameSuggestion {
    public static func make(
        for url: URL,
        mimeType: String,
        documentTitle: String? = nil
    ) -> String {
        let hasFilename = !url.hasDirectoryPath && !url.lastPathComponent.isEmpty
        var name = hasFilename
            ? url.lastPathComponent
            : documentTitle.map(sanitize) ?? "untitled"

        if name.contains(".") { return name }
        switch mimeType {
        case "text/gemini": name += ".gmi"
        case "text/plain": name += ".txt"
        case "image/png": name += ".png"
        case "image/jpeg": name += ".jpg"
        case "image/gif": name += ".gif"
        default: break
        }
        return name
    }

    private static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let sanitized = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "untitled" : sanitized
    }
}
