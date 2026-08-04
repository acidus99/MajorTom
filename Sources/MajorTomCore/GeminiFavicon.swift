import Foundation

/// Validation of a capsule's `favicon.txt`, per Michael Lazar's favicon RFC.
///
/// The document is a single emoji with an optional trailing newline. The RFC is explicit
/// that a client "SHALL NOT render any favicon that does not conform", which rules out
/// ordinary text, several emoji in a row, and bare characters like `1` or `#` that are
/// only emoji when combined with a keycap.
public enum GeminiFavicon {
    /// The path a favicon always lives at, relative to the server root.
    public static let path = "/favicon.txt"

    /// Returns the emoji to display, or `nil` when the document does not conform.
    public static func parse(_ body: String) -> String? {
        // "The document may optionally end in a newline… The newline does not contain any
        // semantic meaning and MUST be removed by the client." Exactly one terminator is
        // removed: a document with two trailing newlines is not conformant.
        //
        // Swift treats CRLF as one Character, so a single drop covers both LF and CRLF —
        // dropping two would take the emoji with it.
        var candidate = Substring(body)
        if let terminator = candidate.last, terminator == "\r\n" || terminator == "\n" {
            candidate = candidate.dropLast()
        }

        // One grapheme cluster, which is what makes a skin-tone modifier or a
        // zero-width-joiner sequence count as the single character the RFC intends.
        guard candidate.count == 1, let character = candidate.first else { return nil }
        guard isEmoji(character) else { return nil }
        return String(character)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars

        // Emoji_Presentation covers the pictographs that render as emoji on their own,
        // including skin-tone modifiers and the components of joined sequences.
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }

        // Text-default symbols become emoji only when followed by VARIATION SELECTOR-16,
        // which is how heart and hourglass are written as emoji.
        let hasPresentationSelector = scalars.contains { $0.value == 0xFE0F }
        if hasPresentationSelector, scalars.contains(where: { $0.properties.isEmoji }) {
            return true
        }

        // A flag is a pair of regional indicators and has no Emoji_Presentation scalar of
        // its own on some platforms, so it is recognised by shape.
        let regionalIndicators = scalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
        return regionalIndicators.count == 2 && regionalIndicators.count == scalars.count
    }
}
