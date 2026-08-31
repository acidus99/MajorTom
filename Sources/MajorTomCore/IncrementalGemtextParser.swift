import Foundation

public enum GemtextEvent: Equatable, Sendable {
    case text(String)
    case heading(level: Int, text: String)
    case link(destination: String, label: String?)
    case listItem(String)
    case quote(String)
    case blank
    case beginPreformatted(altText: String?)
    case preformattedLine(String)
    case endPreformatted
}

public struct IncrementalGemtextParser: Sendable {
    private var lineBuffer = ""
    private var isPreformatted = false
    private var hasSeenFirstCharacter = false

    public init() {}

    public mutating func receive(_ text: String) -> [GemtextEvent] {
        guard !text.isEmpty else { return [] }
        lineBuffer.append(text)

        var events: [GemtextEvent] = []
        var consumed = lineBuffer.startIndex
        var index = lineBuffer.startIndex
        while index < lineBuffer.endIndex {
            guard isLineEnding(lineBuffer[index]) else {
                index = lineBuffer.index(after: index)
                continue
            }
            let next = lineBuffer.index(after: index)
            // A trailing CR may be the first half of a CRLF sequence split across
            // network chunks. Keep it until the next chunk makes that clear.
            if lineBuffer[index] == "\r", next == lineBuffer.endIndex { break }
            events.append(contentsOf: parseCompletedLine(String(lineBuffer[consumed..<index])))
            consumed = next
            index = next
        }

        // One removal for everything consumed, rather than one per line.
        //
        // Removing each line from the front as it was parsed shifted the whole remainder
        // of the buffer every time, and the scan for the next line ending restarted from
        // the front as well. Both are linear, so a single 64 KB network chunk carrying a
        // thousand lines did on the order of a thousand shifts over a shrinking 64 KB
        // buffer — quadratic in the size of the chunk, for one screen of text.
        if consumed > lineBuffer.startIndex {
            lineBuffer.removeSubrange(lineBuffer.startIndex..<consumed)
        }
        return events
    }

    /// Gemtext terminates lines with CRLF, and tolerates a bare LF. `Character.isNewline`
    /// additionally matches VT, FF, NEL, U+2028 and U+2029, which are ordinary text in a
    /// capsule and must not split a line. Note that Swift treats "\r\n" as one Character.
    private func isLineEnding(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    public mutating func finish() -> [GemtextEvent] {
        var events: [GemtextEvent] = []
        if !lineBuffer.isEmpty {
            var line = lineBuffer
            if line.last == "\r" { line.removeLast() }
            events.append(contentsOf: parseCompletedLine(line))
            lineBuffer = ""
        }
        if isPreformatted {
            isPreformatted = false
            events.append(.endPreformatted)
        }
        return events
    }

    private mutating func parseCompletedLine(_ originalLine: String) -> [GemtextEvent] {
        var line = originalLine
        if !hasSeenFirstCharacter {
            hasSeenFirstCharacter = true
            if line.first == "\u{FEFF}" { line.removeFirst() }
        }

        if line.hasPrefix("```") {
            if isPreformatted {
                isPreformatted = false
                return [.endPreformatted]
            }

            isPreformatted = true
            let alt = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return [.beginPreformatted(altText: alt.isEmpty ? nil : alt)]
        }

        if isPreformatted {
            return [.preformattedLine(line)]
        }

        if line.isEmpty { return [.blank] }

        if let heading = parseHeading(line) { return [heading] }
        if let link = parseLink(line) { return [link] }
        if line.hasPrefix("* ") { return [.listItem(String(line.dropFirst(2)))] }
        if line.first == ">" {
            return [.quote(String(line.dropFirst()).dropLeadingSpace())]
        }
        return [.text(line)]
    }

    private func parseHeading(_ line: String) -> GemtextEvent? {
        for level in stride(from: 3, through: 1, by: -1) {
            let marker = String(repeating: "#", count: level) + " "
            if line.hasPrefix(marker) {
                return .heading(level: level, text: String(line.dropFirst(marker.count)))
            }
        }
        return nil
    }

    private func parseLink(_ line: String) -> GemtextEvent? {
        guard line.hasPrefix("=>") else { return nil }
        let remainder = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return .text(line) }

        let pieces = remainder.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let destination = String(pieces[0])
        let label = pieces.count == 2
            ? String(pieces[1]).trimmingCharacters(in: .whitespaces)
            : nil
        return .link(destination: destination, label: label?.isEmpty == true ? nil : label)
    }
}

private extension String {
    func dropLeadingSpace() -> String {
        first == " " ? String(dropFirst()) : self
    }
}
