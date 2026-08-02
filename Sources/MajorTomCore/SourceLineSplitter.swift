import Foundation

/// Splits a decoded response body into the lines shown by Show Page Source.
///
/// This exists because `String.components(separatedBy: .newlines)` treats CR and LF
/// as two separate separators, so every CRLF document came back with a blank line
/// between each real line and twice as many line numbers as it has lines. It also
/// splits on VT, FF, NEL, LS and PS, none of which terminate a line in Gemtext.
public enum SourceLineSplitter {
    /// Splits on CRLF, LF, or a lone CR — and on nothing else.
    ///
    /// A single trailing empty line produced by a document that ends in a line
    /// terminator is dropped, so a 3-line file numbers 1...3 rather than 1...4.
    public static func lines(of source: String) -> [String] {
        guard !source.isEmpty else { return [""] }

        var lines: [String] = []
        var current = ""
        var iterator = source.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?

        while let scalar = pending ?? iterator.next() {
            pending = nil
            switch scalar {
            case "\r":
                // Consume the LF of a CRLF pair; a lone CR still ends the line.
                if let next = iterator.next(), next != "\n" { pending = next }
                lines.append(current)
                current = ""
            case "\n":
                lines.append(current)
                current = ""
            default:
                current.unicodeScalars.append(scalar)
            }
        }

        if !current.isEmpty || lines.isEmpty { lines.append(current) }
        return lines
    }
}
