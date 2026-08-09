import Foundation

/// Picks a document's title out of the events streaming from a Gemtext document.
///
/// The first non-empty heading names the document, regardless of heading level. If a
/// preformatted block opens first, its non-empty fence caption may name the document
/// provisionally; a later heading takes precedence. Any other non-empty content closes
/// the title-claim window, leaving the caller's URL-derived fallback in place.
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
    private var stoppedLooking = false

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
        case .heading(level: _, text: let heading):
            // The first non-empty heading wins; later headings are section titles.
            guard !stoppedLooking, source != .heading else { return false }
            return adopt(heading, as: .heading)
        case .beginPreformatted(let altText):
            guard !stoppedLooking, source == .none, let altText else { return false }
            return adopt(altText, as: .preformattedAlt)
        case .preformattedLine(let line):
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stoppedLooking = true
            }
            return false
        case .text(let text), .listItem(let text), .quote(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stoppedLooking = true
            }
            return false
        case .link:
            stoppedLooking = true
            return false
        default:
            return false
        }
    }

    private mutating func adopt(_ candidate: String, as source: Source) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank heading carries no title and does not close the claim window.
        guard !trimmed.isEmpty else { return false }
        // The claim is recorded either way: re-offering the title already in place
        // still promotes a fence-strength claim to heading strength.
        defer { self.source = source }
        guard trimmed != title else { return false }
        title = trimmed
        return true
    }
}
