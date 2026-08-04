import Foundation

public extension CapsuleEndpoint {
    /// The server a URL belongs to: host plus *effective* port.
    ///
    /// A host reached on a different port is a different server — the favicon RFC §2
    /// says so explicitly, and trust is already pinned per endpoint — so the port has
    /// to be part of the identity even when it is only implied by the scheme.
    init?(url: URL) {
        guard let host = url.host, !host.isEmpty else { return nil }
        let resolvedPort = url.port ?? Int(GeminiRequestTarget.defaultPort)
        guard let port = UInt16(exactly: resolvedPort) else { return nil }
        self.init(host: host, port: port)
    }
}

/// The glyph shown ahead of a link's label to telegraph where that link leads.
///
/// A Gemtext link is a bare line of text, so nothing distinguishes a link that stays
/// inside the capsule from one that leaves Geminispace entirely without reading the
/// URL. Legacy Major Tom hinted at images only; these hints add locality and scheme,
/// which is what a reader usually wants to know before clicking.
public enum GemtextLinkHint: String, Equatable, Sendable {
    /// U+2192 — a gemini link within the capsule currently being read.
    case sameCapsule = "\u{2192}"
    /// U+21D2 — a gemini link to another capsule, or to the same host on another port.
    case otherCapsule = "\u{21D2}"
    /// U+1F310 globe with meridians — an http/https resource, outside Geminispace.
    case web = "\u{1F310}"
    /// A resource that is probably an image, including `data:image/…`.
    case image = "\u{1F5BC}\u{FE0F}"
    /// A `mailto:` address.
    case email = "\u{1F4E7}"

    /// Paths ending in one of these are treated as images, both for hinting and for
    /// deciding what may be loaded inline.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif"
    ]

    public static func isProbableImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether a link can be expanded in place when clicked.
    ///
    /// Restricted to gemini resources that look like images: a `data:image/` link is
    /// already inline in the document, and fetching an http image would leave
    /// Geminispace, which a click on a Gemtext link should never do silently.
    public static func isInlineImageCandidate(destination: String, relativeTo baseURL: URL?) -> Bool {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              resolved.scheme?.lowercased() == "gemini" else { return false }
        return isProbableImage(resolved)
    }

    /// Whether two URLs live on the same capsule, i.e. the same host *and* port.
    public static func isSameCapsule(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = CapsuleEndpoint(url: lhs), let right = CapsuleEndpoint(url: rhs) else {
            return false
        }
        return left == right
    }

    /// Classifies a raw Gemtext link destination, which may be relative.
    ///
    /// Scheme is checked before content: an `http` link to a `.png` reports as web
    /// rather than as an image, because leaving Geminispace is the more consequential
    /// fact and the one a reader wants flagged. Within a capsule the reverse holds —
    /// locality is a given, so the image glyph is the more informative one.
    ///
    /// Returns `nil` for schemes Major Tom has no hint for, which renders no glyph
    /// rather than a misleading one.
    public static func classify(destination: String, relativeTo baseURL: URL?) -> GemtextLinkHint? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A data: URI can be enormous, and URL(string:) on one is wasteful when the
        // prefix already settles the question.
        if trimmed.lowercased().hasPrefix("data:") {
            return trimmed.lowercased().hasPrefix("data:image/") ? .image : nil
        }

        guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }

        switch resolved.scheme?.lowercased() {
        case "mailto":
            return .email
        case "http", "https":
            return .web
        case "gemini":
            if isProbableImage(resolved) { return .image }
            // With no base URL there is no capsule to be "same" as, so an absolute
            // gemini link is reported as the jump it is.
            guard let baseURL, baseURL.scheme?.lowercased() == "gemini" else {
                return .otherCapsule
            }
            return isSameCapsule(resolved, baseURL) ? .sameCapsule : .otherCapsule
        case "file":
            // Relative links inside a local document. Treated as staying "here".
            return isProbableImage(resolved) ? .image : .sameCapsule
        default:
            return nil
        }
    }
}
