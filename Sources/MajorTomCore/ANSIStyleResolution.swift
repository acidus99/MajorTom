import Foundation

public extension ContentThemeColor {
    /// WCAG 2.1 relative luminance.
    var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.1 contrast ratio, 1 (identical) through 21 (black on white).
    func contrastRatio(against other: ContentThemeColor) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

/// Moves an author's color the smallest distance that makes it readable on a given
/// background, keeping its hue.
public enum ANSIContrast {
    /// The floor every ANSI foreground is held to, matching the ratio the content
    /// themes themselves are tested against.
    ///
    /// A floor necessarily flattens the dark end of a long ramp — the bottom of a
    /// 256-color grayscale gradient on a dark theme all lands on the same readable
    /// gray. That is the intended trade: a capsule can make its art dimmer than the
    /// reader's theme can show, and unreadable text is the worse failure.
    public static let minimumRatio = 4.5

    /// Below this background luminance white is the readable extreme and above it
    /// black is. Any threshold in 0.175...0.183 has both extremes clearing 4.5, so
    /// one of the two directions always has a solution.
    private static let lightBackgroundLuminance = 0.179

    public static func adapted(
        _ color: ContentThemeColor,
        on background: ContentThemeColor,
        minimumRatio: Double = ANSIContrast.minimumRatio
    ) -> ContentThemeColor {
        // An author color that already reads clearly is left exactly as written. On a
        // dark theme that is most of them, which is why dark backgrounds show a
        // capsule's palette essentially untouched.
        guard color.contrastRatio(against: background) < minimumRatio else { return color }

        let lighten = background.relativeLuminance < lightBackgroundLuminance
        let (hue, saturation, lightness) = color.hsl
        var low = lighten ? lightness : 0
        var high = lighten ? 1 : lightness

        // Bisect on the quantized color, so whichever bound is returned is a color
        // that was itself measured as passing rather than one rounding might sink
        // back below the floor. The starting bound in the chosen direction is white
        // or black, which always passes.
        for _ in 0..<16 {
            let middle = (low + high) / 2
            let candidate = ContentThemeColor(
                hue: hue,
                saturation: saturation,
                lightness: middle
            )
            let passes = candidate.contrastRatio(against: background) >= minimumRatio
            if passes == lighten { high = middle } else { low = middle }
        }
        return ContentThemeColor(
            hue: hue,
            saturation: saturation,
            lightness: lighten ? high : low
        )
    }
}

extension ContentThemeColor {
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let red = Double(self.red) / 255
        let green = Double(self.green) / 255
        let blue = Double(self.blue) / 255
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let lightness = (highest + lowest) / 2
        guard highest > lowest else { return (0, 0, lightness) }

        let range = highest - lowest
        let saturation = lightness > 0.5
            ? range / (2 - highest - lowest)
            : range / (highest + lowest)
        var hue: Double
        switch highest {
        case red: hue = (green - blue) / range + (green < blue ? 6 : 0)
        case green: hue = (blue - red) / range + 2
        default: hue = (red - green) / range + 4
        }
        hue /= 6
        return (hue, saturation, lightness)
    }

    init(hue: Double, saturation: Double, lightness: Double) {
        func channel(_ offset: Double) -> UInt8 {
            guard saturation > 0 else { return UInt8((lightness * 255).rounded()) }
            let chroma = lightness < 0.5
                ? lightness * (1 + saturation)
                : lightness + saturation - lightness * saturation
            let base = 2 * lightness - chroma
            var position = hue + offset
            if position < 0 { position += 1 }
            if position > 1 { position -= 1 }
            let value: Double
            if position < 1.0 / 6 {
                value = base + (chroma - base) * 6 * position
            } else if position < 1.0 / 2 {
                value = chroma
            } else if position < 2.0 / 3 {
                value = base + (chroma - base) * (2.0 / 3 - position) * 6
            } else {
                value = base
            }
            return UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(
            red: channel(1.0 / 3),
            green: channel(0),
            blue: channel(-1.0 / 3)
        )
    }
}

/// ANSI attributes reduced to the colors and traits a run of text is drawn with.
public struct ResolvedANSIStyle: Equatable, Sendable {
    public var foreground: ContentThemeColor?
    public var background: ContentThemeColor?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool

    public init(
        foreground: ContentThemeColor? = nil,
        background: ContentThemeColor? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
    }

    public var isPlain: Bool {
        foreground == nil && background == nil && !isBold && !isItalic && !isUnderlined
    }

    /// Declarations for the span wrapping this run. Empty when nothing is set, so the
    /// text can be emitted without a wrapper at all.
    public var css: String {
        var declarations: [String] = []
        if let foreground { declarations.append("color:\(foreground.cssHex)") }
        if let background { declarations.append("background-color:\(background.cssHex)") }
        if isBold { declarations.append("font-weight:bold") }
        if isItalic { declarations.append("font-style:italic") }
        if isUnderlined { declarations.append("text-decoration:underline") }
        return declarations.joined(separator: ";")
    }
}

/// Turns the ANSI attributes an author wrote into colors that stay readable on the
/// reader's own content theme.
///
/// Two rules do the work, both taken from Lagrange:
///
/// - A foreground is adapted to the theme background, so a capsule cannot produce
///   text the reader cannot see.
/// - A background is honored only on a run that also sets a foreground, and only when
///   the reader has asked for backgrounds at all. A bare background inherits the
///   theme's own text color, which the author never saw and which can land invisibly
///   close to the background they chose.
public struct ANSIStyleResolver: Equatable, Sendable {
    public let themeForeground: ContentThemeColor
    public let themeBackground: ContentThemeColor
    public let rendersBackgroundColors: Bool

    public init(
        themeForeground: ContentThemeColor,
        themeBackground: ContentThemeColor,
        rendersBackgroundColors: Bool
    ) {
        self.themeForeground = themeForeground
        self.themeBackground = themeBackground
        self.rendersBackgroundColors = rendersBackgroundColors
    }

    public func resolve(_ style: ANSIStyle) -> ResolvedANSIStyle {
        var resolved = ResolvedANSIStyle(
            isBold: style.isBold,
            isItalic: style.isItalic,
            isUnderlined: style.isUnderlined
        )

        var authorForeground = style.foreground?.resolved(bold: style.isBold)
        var authorBackground = style.background?.resolved(bold: false)
        if style.isInverse {
            // Reverse video swaps the two, and whichever side the author left at its
            // default takes the theme's own color. A run that set only a foreground
            // therefore comes out of the swap with both sides set, which is what the
            // background rule below asks for.
            (authorForeground, authorBackground) = (
                authorBackground ?? themeBackground,
                authorForeground ?? themeForeground
            )
        }

        guard let authorForeground else { return resolved }
        if rendersBackgroundColors, let authorBackground {
            resolved.background = authorBackground
        }
        // Readability is measured against whatever this run is actually drawn on: the
        // author's own background where one is shown, the theme's where it is not.
        resolved.foreground = ANSIContrast.adapted(
            authorForeground,
            on: resolved.background ?? themeBackground
        )
        return resolved
    }
}
