import Foundation

public enum BrowserFilenameSuggestion {
    public static func make(
        for url: URL,
        mimeType: String,
        documentTitle: String? = nil
    ) -> String {
        let hasFilename = !url.hasDirectoryPath && !url.lastPathComponent.isEmpty
        guard hasFilename else {
            // A period inside a document title is prose, not a file extension, so the
            // extension for the response's type is still needed: titles as ordinary as
            // "Gemi.dev Heavy Industries" or "Release notes for v2.0" used to be
            // offered with no extension at all.
            return named(documentTitle.map(sanitize) ?? "untitled", as: mimeType)
        }
        // The last path component's own extension is the capsule's choice of name and
        // is preserved even when it disagrees with the response's type.
        guard url.pathExtension.isEmpty else { return sanitize(url.lastPathComponent) }
        return named(sanitize(url.lastPathComponent), as: mimeType)
    }

    private static func named(_ name: String, as mimeType: String) -> String {
        let suffix = filenameExtension(for: mimeType)
        guard !suffix.isEmpty, !name.lowercased().hasSuffix(suffix) else { return name }
        return name + suffix
    }

    private static func filenameExtension(for mimeType: String) -> String {
        // Callers pass the media type without its parameters, but normalizing here
        // keeps a stray "Text/Gemini" or trailing space from losing the extension.
        switch mimeType.trimmingCharacters(in: .whitespaces).lowercased() {
        case "text/gemini": return ".gmi"
        case "text/plain": return ".txt"
        case "image/png": return ".png"
        case "image/jpeg": return ".jpg"
        case "image/gif": return ".gif"
        default: return ""
        }
    }

    private static func sanitize(_ value: String) -> String {
        // "/" and ":" are both path separators on macOS depending on the interface
        // asked, and control characters — a newline in a heading, most plausibly —
        // have no business in a filename.
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var sanitized = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading period hides the file, which is never what saving a page titled
        // ".plan" was meant to do.
        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
            sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitized.isEmpty ? "untitled" : sanitized
    }
}
