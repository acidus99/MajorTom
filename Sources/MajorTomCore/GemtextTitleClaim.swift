import Foundation

/// Picks a document's title out of the events streaming from a Gemtext document.
///
/// A level-one heading names the document. Failing that, the text on the opening fence
/// of the *first* preformatted block does: that text is conventionally a caption for
/// ASCII art, and on a banner-style capsule page it is the only title present. Legacy
/// Major Tom used the same two-tier rule (`GmiToHtml.preTitle`).
///
/// A heading always outranks fence text even when the preformatted block arrives first,
/// which matters because titles are claimed while the response is still streaming and
/// cannot wait for the whole document.
public struct GemtextTitleClaim: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Nothing has named the document; a caller should use its own fallback.
        case none
        case preformattedAlt
        case heading
    }

    public private(set) var source: Source = .none
    public private(set) var title: String?

    /// - Parameter existingTitle: a title already known for this document, e.g. one
    ///   restored from cache. Treated as a heading-strength claim so that re-rendering
    ///   a cached page cannot downgrade its title to some later fence caption.
    public init(existingTitle: String? = nil) {
        if let existingTitle, !existingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = existingTitle
            source = .heading
        }
    }

    /// Offers one event to the claim.
    ///
    /// - Returns: `true` when `title` changed, so a caller can republish state only
    ///   when there is something new to publish.
    public mutating func receive(_ event: GemtextEvent) -> Bool {
        switch event {
        case .heading(level: 1, text: let heading):
            // The first heading wins; later ones are section titles, not the document's.
            guard source != .heading else { return false }
            return adopt(heading, as: .heading)
        case .beginPreformatted(let altText):
            guard source == .none, let altText else { return false }
            return adopt(altText, as: .preformattedAlt)
        default:
            return false
        }
    }

    private mutating func adopt(_ candidate: String, as source: Source) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank heading carries no title, and must not lock out a fence caption that
        // follows it.
        guard !trimmed.isEmpty else { return false }
        // The claim is recorded either way: re-offering the title already in place
        // still promotes a fence-strength claim to heading strength.
        defer { self.source = source }
        guard trimmed != title else { return false }
        title = trimmed
        return true
    }
}
