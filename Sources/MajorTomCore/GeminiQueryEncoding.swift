import Foundation

/// Percent-encodes a user-supplied string for the query component of a Gemini URL.
///
/// `URLQueryItem` uses `CFURLComponents`' query rules, which leave the sub-delimiters
/// `+`, `/`, `?`, `;`, `,`, `$` and `:` unescaped. A capsule that decodes its query with
/// a CGI-style library reads a literal `+` as a space, so searching for `C++` or
/// answering an input prompt with `a+b` silently delivered different text than the user
/// typed.
///
/// Encoding everything outside RFC 3986's *unreserved* set is what Gemini clients
/// conventionally do and is unambiguous for every server-side decoder.
public enum GeminiQueryEncoding {
    /// RFC 3986 §2.3 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Returns `base` with its query replaced by the encoded `value`.
    ///
    /// The query is assembled textually rather than through `URLComponents.queryItems`,
    /// because assigning `queryItems` re-encodes with the permissive query rules and
    /// would undo the encoding above.
    public static func url(base: URL, query value: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedQuery = encode(value)
        return components.url
    }
}
