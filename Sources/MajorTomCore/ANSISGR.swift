import Foundation

/// A color named by an ANSI SGR sequence.
///
/// The three cases are kept apart rather than resolved to RGB at parse time because
/// bold brightens the sixteen legacy colors and nothing else: `<ESC>[1;31m` is bright
/// red, while `<ESC>[1;38;5;1m` stays the palette's dim red.
public enum ANSIColor: Equatable, Sendable {
    /// One of the sixteen legacy colors, 0...15. Set by codes 30-37, 40-47, 90-97
    /// and 100-107.
    case legacy(Int)
    /// An index into the 256-color palette, set by `38;5;n` or `48;5;n`.
    case palette(Int)
    /// A direct 24-bit color, set by `38;2;r;g;b` or `48;2;r;g;b`.
    case rgb(red: UInt8, green: UInt8, blue: UInt8)

    /// - Parameter bold: brightens a legacy color 0...7 to its 8...15 counterpart,
    ///   the behavior terminals have had since bold on a monochrome tube meant
    ///   "brighter" and which most ANSI art relies on for its light tones.
    public func resolved(bold: Bool) -> ContentThemeColor {
        switch self {
        case .legacy(let index):
            let brightened = bold && index < 8 ? index + 8 : index
            return Self.legacyPalette[min(max(brightened, 0), 15)]
        case .palette(let index):
            return Self.paletteColor(index)
        case .rgb(let red, let green, let blue):
            return ContentThemeColor(red: red, green: green, blue: blue)
        }
    }

    /// xterm's default sixteen colors. Chosen over the dimmer VGA set because it is
    /// what authors preview their capsules against, and because indices 0...15 of the
    /// 256-color palette are these same colors, so one table keeps both consistent.
    static let legacyPalette: [ContentThemeColor] = [
        ContentThemeColor(red: 0x00, green: 0x00, blue: 0x00),
        ContentThemeColor(red: 0xcd, green: 0x00, blue: 0x00),
        ContentThemeColor(red: 0x00, green: 0xcd, blue: 0x00),
        ContentThemeColor(red: 0xcd, green: 0xcd, blue: 0x00),
        ContentThemeColor(red: 0x00, green: 0x00, blue: 0xee),
        ContentThemeColor(red: 0xcd, green: 0x00, blue: 0xcd),
        ContentThemeColor(red: 0x00, green: 0xcd, blue: 0xcd),
        ContentThemeColor(red: 0xe5, green: 0xe5, blue: 0xe5),
        ContentThemeColor(red: 0x7f, green: 0x7f, blue: 0x7f),
        ContentThemeColor(red: 0xff, green: 0x00, blue: 0x00),
        ContentThemeColor(red: 0x00, green: 0xff, blue: 0x00),
        ContentThemeColor(red: 0xff, green: 0xff, blue: 0x00),
        ContentThemeColor(red: 0x5c, green: 0x5c, blue: 0xff),
        ContentThemeColor(red: 0xff, green: 0x00, blue: 0xff),
        ContentThemeColor(red: 0x00, green: 0xff, blue: 0xff),
        ContentThemeColor(red: 0xff, green: 0xff, blue: 0xff)
    ]

    /// The xterm 256-color palette: the sixteen legacy colors, a 6x6x6 RGB cube, then
    /// a 24-step grayscale ramp.
    static func paletteColor(_ index: Int) -> ContentThemeColor {
        guard (0...255).contains(index) else {
            return ContentThemeColor(red: 0, green: 0, blue: 0)
        }
        if index < 16 { return legacyPalette[index] }
        if index < 232 {
            let cubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let offset = index - 16
            return ContentThemeColor(
                red: cubeLevels[(offset / 36) % 6],
                green: cubeLevels[(offset / 6) % 6],
                blue: cubeLevels[offset % 6]
            )
        }
        let level = UInt8(8 + (index - 232) * 10)
        return ContentThemeColor(red: level, green: level, blue: level)
    }
}

/// The subset of SGR attributes Major Tom renders.
///
/// Everything else an SGR sequence can set — blink, conceal, framing, alternative
/// fonts — is parsed and discarded: a static document has no cursor and no terminal,
/// so those attributes have nothing to act on.
public struct ANSIStyle: Equatable, Sendable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isInverse: Bool

    public init(
        foreground: ANSIColor? = nil,
        background: ANSIColor? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isInverse: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isInverse = isInverse
    }

    public var isPlain: Bool { self == ANSIStyle() }

    /// Applies the parameters of one `<ESC>[...m` sequence.
    ///
    /// - Parameter parameters: the text between `<ESC>[` and `m`. An empty string is
    ///   `<ESC>[m`, which ECMA-48 defines as a full reset.
    public mutating func apply(sgrParameters parameters: String) {
        let fields = parameters.isEmpty ? [""] : parameters.components(separatedBy: ";")
        var index = 0
        while index < fields.count {
            let field = fields[index]
            // T.416 allows an extended color to arrive as one colon-joined field
            // (`38:5:208`) instead of several semicolon-joined ones. Colons also carry
            // unrelated sub-parameters such as `4:3` for a curly underline, which
            // `extendedColor` rejects.
            if field.contains(":") {
                if let color = Self.extendedColor(colonJoined: field) {
                    if color.isForeground { foreground = color.color } else { background = color.color }
                }
                index += 1
                continue
            }
            // An omitted parameter means zero.
            guard let code = Int(field.isEmpty ? "0" : field) else {
                index += 1
                continue
            }
            switch code {
            case 0: self = ANSIStyle()
            case 1: isBold = true
            case 3: isItalic = true
            case 4: isUnderlined = true
            case 7: isInverse = true
            case 22: isBold = false
            case 23: isItalic = false
            case 24: isUnderlined = false
            case 27: isInverse = false
            case 30...37: foreground = .legacy(code - 30)
            case 39: foreground = nil
            case 40...47: background = .legacy(code - 40)
            case 49: background = nil
            case 90...97: foreground = .legacy(code - 90 + 8)
            case 100...107: background = .legacy(code - 100 + 8)
            case 38, 48:
                let extended = Self.extendedColor(fields, at: index)
                if code == 38 { foreground = extended.color } else { background = extended.color }
                index += extended.consumed - 1
            default: break
            }
            index += 1
        }
    }

    /// Reads `38;5;n`, `38;2;r;g;b` and their `48` counterparts.
    ///
    /// - Returns: the color, or nil when the sequence is malformed, together with how
    ///   many fields to consume. A malformed extended color consumes the selector and
    ///   its kind so the remaining fields are still read as ordinary attributes.
    private static func extendedColor(
        _ fields: [String],
        at index: Int
    ) -> (color: ANSIColor?, consumed: Int) {
        guard index + 1 < fields.count, let kind = Int(fields[index + 1]) else {
            return (nil, 1)
        }
        switch kind {
        case 5:
            guard index + 2 < fields.count,
                  let value = Int(fields[index + 2]),
                  (0...255).contains(value) else { return (nil, 2) }
            return (.palette(value), 3)
        case 2:
            guard index + 4 < fields.count,
                  let red = channel(fields[index + 2]),
                  let green = channel(fields[index + 3]),
                  let blue = channel(fields[index + 4]) else { return (nil, 2) }
            return (.rgb(red: red, green: green, blue: blue), 5)
        default:
            return (nil, 2)
        }
    }

    private static func extendedColor(
        colonJoined field: String
    ) -> (color: ANSIColor?, isForeground: Bool)? {
        let parts = field.components(separatedBy: ":")
        guard let selector = Int(parts[0]), selector == 38 || selector == 48,
              parts.count >= 2, let kind = Int(parts[1]) else { return nil }
        let isForeground = selector == 38
        switch kind {
        case 5:
            guard parts.count >= 3, let value = Int(parts[2]), (0...255).contains(value) else {
                return (nil, isForeground)
            }
            return (.palette(value), isForeground)
        case 2:
            // T.416 puts an optional color-space identifier ahead of the channels, so
            // both `2:r:g:b` and `2::r:g:b` occur in the wild.
            let channels = parts.count >= 6 ? Array(parts[3...5]) : Array(parts.dropFirst(2))
            guard channels.count == 3,
                  let red = channel(channels[0]),
                  let green = channel(channels[1]),
                  let blue = channel(channels[2]) else { return (nil, isForeground) }
            return (.rgb(red: red, green: green, blue: blue), isForeground)
        default:
            return nil
        }
    }

    private static func channel(_ field: String) -> UInt8? {
        guard let value = Int(field), (0...255).contains(value) else { return nil }
        return UInt8(value)
    }
}

/// A stretch of preformatted text sharing one set of ANSI attributes.
public struct ANSITextRun: Equatable, Sendable {
    public let text: String
    public let style: ANSIStyle

    public init(text: String, style: ANSIStyle) {
        self.text = text
        self.style = style
    }
}

/// Splits one line of preformatted text into runs at its ANSI SGR sequences.
///
/// Deliberately not a terminal emulator. A Gemini response is a static document, so
/// there is no cursor for a movement or erase sequence to act on; those sequences are
/// recognized only well enough to be removed from the text. Attributes do not carry
/// across lines either — each call starts from the default style, which is both what
/// Lagrange does and what ANSI art needs, because authors set the color afresh on
/// every line rather than trusting a client to hold state.
public enum ANSISGRParser {
    private static let escape: Unicode.Scalar = "\u{1B}"

    public static func runs(in line: String) -> [ANSITextRun] {
        guard line.unicodeScalars.contains(escape) else {
            return line.isEmpty ? [] : [ANSITextRun(text: line, style: ANSIStyle())]
        }

        let scalars = Array(line.unicodeScalars)
        var runs: [ANSITextRun] = []
        var style = ANSIStyle()
        var pending = String.UnicodeScalarView()
        var index = 0

        func flush() {
            guard !pending.isEmpty else { return }
            runs.append(ANSITextRun(text: String(pending), style: style))
            pending = String.UnicodeScalarView()
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == escape else {
                pending.append(scalar)
                index += 1
                continue
            }
            let sequence = skipSequence(scalars, from: index)
            index = sequence.next
            // Only an SGR sequence ends a run. Text either side of a cursor or erase
            // sequence keeps the style it already had, and so stays one run.
            guard let parameters = sequence.sgrParameters else { continue }
            flush()
            style.apply(sgrParameters: parameters)
        }
        flush()
        return runs
    }

    /// Measures the escape sequence beginning at `start`.
    ///
    /// - Returns: the index just past the sequence, and its parameter text when the
    ///   sequence is SGR. An unterminated sequence runs to the end of the line, which
    ///   is correct here: a truncated sequence is not text the author meant to show,
    ///   and style never carries to the next line anyway.
    private static func skipSequence(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> (next: Int, sgrParameters: String?) {
        var index = start + 1
        guard index < scalars.count else { return (index, nil) }
        let introducer = scalars[index]
        index += 1

        switch introducer {
        case "[":
            var parameters = String.UnicodeScalarView()
            while index < scalars.count, (0x30...0x3F).contains(scalars[index].value) {
                parameters.append(scalars[index])
                index += 1
            }
            var hasIntermediate = false
            while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) {
                hasIntermediate = true
                index += 1
            }
            guard index < scalars.count, (0x40...0x7E).contains(scalars[index].value) else {
                return (scalars.count, nil)
            }
            let final = scalars[index]
            index += 1
            // A private-use parameter such as `<ESC>[?25l` or an intermediate byte
            // means the sequence is not SGR however it ends.
            let isSGRParameters = parameters.allSatisfy {
                ("0"..."9").contains($0) || $0 == ";" || $0 == ":"
            }
            guard final == "m", !hasIntermediate, isSGRParameters else { return (index, nil) }
            return (index, String(parameters))

        case "]", "P", "X", "^", "_":
            // A string sequence — OSC, DCS, SOS, PM or APC — carrying a payload that
            // runs until BEL or the string terminator `<ESC>\`.
            while index < scalars.count {
                if scalars[index] == "\u{07}" { return (index + 1, nil) }
                if scalars[index] == escape,
                   index + 1 < scalars.count,
                   scalars[index + 1] == "\\" {
                    return (index + 2, nil)
                }
                index += 1
            }
            return (scalars.count, nil)

        default:
            // An nF sequence such as `<ESC>(B` carries intermediate bytes ahead of its
            // final byte; every other escape is two characters long.
            guard (0x20...0x2F).contains(introducer.value) else { return (index, nil) }
            while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) {
                index += 1
            }
            return (index < scalars.count ? index + 1 : index, nil)
        }
    }
}
