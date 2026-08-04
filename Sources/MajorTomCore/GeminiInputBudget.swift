import Foundation

/// How much room is left for the user's answer to a Gemini input prompt.
///
/// A capsule asking for input (status 10 or 11) receives the answer as the query of a
/// fresh request, and a Gemini request line may be at most 1024 bytes including its
/// CRLF. So the answer competes for space with the URL that asked for it: a prompt at a
/// long path leaves less room than one at the capsule root.
///
/// Two details make a naive character count wrong. The answer is percent-encoded, so
/// one typed character can cost up to twelve bytes (a non-BMP emoji is four UTF-8 bytes,
/// each encoded as `%XX`), and the budget is measured in bytes rather than characters.
/// Counting the encoded form is the only way the number shown to someone typing matches
/// what the server will actually receive.
public struct GeminiInputBudget: Equatable, Sendable {
    /// Bytes available for the encoded answer, after the URL and its `?` are accounted
    /// for. Can be zero for a pathological prompt URL, never negative.
    public let maximumEncodedByteCount: Int

    public init(promptURL: URL) {
        // The answer replaces any existing query, so the base excludes it — as
        // GeminiQueryEncoding.url(base:query:) does when it builds the request.
        var components = URLComponents(url: promptURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let base = components?.url?.absoluteString ?? promptURL.absoluteString
        // One byte for the "?" that introduces the query.
        let overhead = base.utf8.count + 1
        maximumEncodedByteCount = max(0, GeminiRequestTarget.maximumURLByteCount - overhead)
    }

    /// The wire cost of `answer`: its length once percent-encoded, in bytes.
    public func encodedByteCount(of answer: String) -> Int {
        GeminiQueryEncoding.encode(answer).utf8.count
    }

    /// Bytes still available. Negative once the answer is too long, by how much.
    public func remainingByteCount(for answer: String) -> Int {
        maximumEncodedByteCount - encodedByteCount(of: answer)
    }

    public func permits(_ answer: String) -> Bool {
        remainingByteCount(for: answer) >= 0
    }
}
