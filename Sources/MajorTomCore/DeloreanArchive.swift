import Foundation

/// Delorean, the archive of past captures that Kennedy keeps of Geminispace.
///
/// When a capsule is gone — a permanent failure, or a host that no longer resolves or
/// answers — the page may still be readable as it was. That is the one moment the archive
/// is worth offering, so this exists to build the link to it.
public enum DeloreanArchive {
    /// The "captures for a specific URL" view. The URL to look up travels as the query.
    public static let capturesEndpoint = URL(string: "gemini://kennedy.gemi.dev/archive/history")!

    /// A link to every capture the archive holds of `url`.
    ///
    /// Only gemini resources are offered. A web page reached through a proxy failed at the
    /// proxy, and Delorean archives Geminispace rather than the web, so pointing someone
    /// there would waste the trip.
    public static func captures(of url: URL) -> URL? {
        guard url.scheme?.lowercased() == "gemini" else { return nil }
        // Percent-encodes everything outside RFC 3986 unreserved, so the whole URL
        // survives as one query value rather than being read as nested query parameters.
        return GeminiQueryEncoding.url(base: capturesEndpoint, query: url.absoluteString)
    }

    /// Whether a failed request is worth offering the archive for.
    ///
    /// A permanent failure means the capsule answered and said the resource is gone. A
    /// connection that never completed — DNS, TCP or the TLS handshake — means the capsule
    /// itself may be gone. Both are cases where an old copy is the only copy.
    ///
    /// Deliberately excluded: anything about identity. A fingerprint that changed or a
    /// trust decision the reader declined is a security signal, and offering a cheerful
    /// "read it from the archive instead" button there would undercut the warning.
    public static func isWorthOffering(status: Int) -> Bool {
        status == 51
    }
}
