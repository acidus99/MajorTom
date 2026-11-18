import Foundation

public struct ContentThemeColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var cssHex: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }
}

public struct ContentThemePalette: Equatable, Sendable {
    public let background: ContentThemeColor
    public let foreground: ContentThemeColor
    public let codeBackground: ContentThemeColor
    public let codeForeground: ContentThemeColor

    public init(
        background: ContentThemeColor, foreground: ContentThemeColor,
        codeBackground: ContentThemeColor, codeForeground: ContentThemeColor? = nil
    ) {
        self.background = background
        self.foreground = foreground
        self.codeBackground = codeBackground
        self.codeForeground = codeForeground ?? foreground
    }

    /// Neutral fallback for renderers used without a presentation environment.
    public static let fallback = ContentThemePalette(
        background: ContentThemeColor(red: 0, green: 0, blue: 0),
        foreground: ContentThemeColor(red: 255, green: 255, blue: 255),
        codeBackground: ContentThemeColor(red: 0, green: 0, blue: 0)
    )
}

