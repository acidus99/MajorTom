import Foundation

/// One content decision is shared by streaming, retained visits, and previews.
public enum BrowserContentKind: Equatable, Sendable {
    case gemtext, plainText, source, image, unsupported

    public init(mimeType: String, url: URL, showsSource: Bool = false) {
        let mime = mimeType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if mime.hasPrefix("text/"), showsSource || ViewSourceURL.isViewSource(url) { self = .source }
        else if mime == "text/gemini" { self = .gemtext }
        else if mime.hasPrefix("text/") { self = .plainText }
        else if mime.hasPrefix("image/") { self = .image }
        else { self = .unsupported }
    }

    public var isText: Bool { self == .gemtext || self == .plainText || self == .source }
    public var streamsText: Bool { self == .gemtext || self == .plainText }
}

public enum BrowserBodyEvent: Equatable, Sendable {
    case gemtext(GemtextEvent)
    case text(String)
}

/// Incremental interpretation only. Received bytes remain the session's authority;
/// opaque bodies and source views are handled after their complete body arrives.
public struct BrowserResponseBody: Sendable {
    public let kind: BrowserContentKind
    private var decoder = IncrementalUTF8Decoder()
    private var parser = IncrementalGemtextParser()
    private var isFinished = false

    public init(kind: BrowserContentKind) { self.kind = kind }

    public mutating func receive(_ bytes: Data) -> [BrowserBodyEvent] {
        guard !isFinished, kind.streamsText else { return [] }
        let text = decoder.decode(bytes)
        if kind == .gemtext { return parser.receive(text).map(BrowserBodyEvent.gemtext) }
        return text.isEmpty ? [] : [.text(text)]
    }

    public mutating func finish() -> [BrowserBodyEvent] {
        guard !isFinished, kind.streamsText else { return [] }
        isFinished = true
        let text = decoder.finish()
        if kind == .gemtext { return (parser.receive(text) + parser.finish()).map(BrowserBodyEvent.gemtext) }
        return text.isEmpty ? [] : [.text(text)]
    }

    public static func events(for bytes: Data, kind: BrowserContentKind) -> [BrowserBodyEvent] {
        var body = BrowserResponseBody(kind: kind)
        return body.receive(bytes) + body.finish()
    }
}

/// Decoding an embedded image is content interpretation, independent of retrieval.
public struct InlineDataImagePayload: Sendable {
    public let data: Data
    public let mimeType: String

    public static func decode(_ source: String) -> InlineDataImagePayload? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let header = String(source[..<comma])
        guard header.lowercased().hasPrefix("data:image/") else { return nil }
        let mime = header.dropFirst("data:".count).split(separator: ";", maxSplits: 1)
            .first.map(String.init)?.lowercased() ?? "image/*"
        let payload = String(source[source.index(after: comma)...])
        let bytes: Data?
        if header.lowercased().contains(";base64") { bytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
        else { bytes = payload.removingPercentEncoding?.data(using: .utf8) }
        guard let bytes else { return nil }
        return InlineDataImagePayload(data: bytes, mimeType: mime)
    }
}
