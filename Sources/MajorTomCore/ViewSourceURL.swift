import Foundation

/// The `view-source:` pseudo-scheme, which wraps another URL to mean "show me this
/// resource's bytes instead of rendering them".
///
/// It is a composed scheme rather than a hierarchical one — `view-source:gemini://host/`
/// has no host, path or query of its own — so `URLComponents` cannot take it apart and
/// every site that handles one has to perform the same string surgery. That agreement
/// lives here rather than being spelled out at each call site.
public enum ViewSourceURL {
    public static let scheme = "view-source"
    private static let prefix = "view-source:"

    public static func isViewSource(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Wraps a resource URL for display as source.
    ///
    /// Returns `nil` for an already-wrapped URL, because `view-source:view-source:` has
    /// no meaning, and for anything that will not re-parse as a URL.
    public static func wrap(_ resourceURL: URL) -> URL? {
        guard !isViewSource(resourceURL) else { return nil }
        return URL(string: prefix + resourceURL.absoluteString)
    }

    /// The resource a `view-source:` URL wraps, or `nil` if `url` is not one.
    public static func unwrap(_ url: URL) -> URL? {
        guard isViewSource(url) else { return nil }
        // Split on the first colon rather than dropping a fixed-length prefix: the
        // scheme's case as typed is not guaranteed to survive into absoluteString.
        let text = url.absoluteString
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let remainder = text[text.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        return URL(string: remainder)
    }

    /// Strips the prefix from raw address-bar text, before it is a `URL` at all.
    ///
    /// - Returns: the inner text, which may be empty if the user typed only the prefix,
    ///   or `nil` when the text is not a view-source address.
    public static func unwrap(text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
