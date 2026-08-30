import Foundation

public enum SearchProvider: String, CaseIterable, Codable, Sendable {
    case kennedy
    case tlgs
    case custom

    public func endpoint(customEndpoint: String?) -> URL {
        switch self {
        case .kennedy:
            return URL(string: "gemini://kennedy.gemi.dev/search")!
        case .tlgs:
            return URL(string: "gemini://tlgs.one/search")!
        case .custom:
            return URL(string: customEndpoint ?? "")
                ?? URL(string: "gemini://kennedy.gemi.dev/search")!
        }
    }
}

public enum ApplicationAppearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}

public enum ContentWidth: String, CaseIterable, Codable, Sendable {
    case narrow
    case wide
    case full

    /// Screen-only so printing can continue to use the full printable page width.
    public var css: String {
        let maxWidth = switch self {
        case .narrow: "48rem"
        case .wide: "56rem"
        case .full: "none"
        }
        return "@media screen { main, .browser-generated main { max-width: \(maxWidth); } }"
    }
}

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
    public let isDark: Bool
    public let background: ContentThemeColor
    public let foreground: ContentThemeColor
    public let muted: ContentThemeColor
    public let accent: ContentThemeColor
    public let link: ContentThemeColor
    public let blockquote: ContentThemeColor
    public let codeBackground: ContentThemeColor
}

public enum ContentTheme: String, CaseIterable, Codable, Sendable {
    case draculaLight
    case draculaDark
    case draculaClassic
    case ocean
    case forest
    case creamsicle
    case sandDunes

    public func palette(effectiveDarkAppearance: Bool) -> ContentThemePalette {
        if let semanticPalette {
            return semanticPalette.contentPalette
        }

        let useDarkPalette: Bool
        switch self {
        case .draculaLight: useDarkPalette = false
        case .draculaDark: useDarkPalette = true
        case .draculaClassic, .ocean, .forest, .creamsicle, .sandDunes:
            preconditionFailure("Semantic themes provide their own resolved palette")
        }

        if useDarkPalette {
            return ContentThemePalette(
                isDark: true,
                background: ContentThemeColor(red: 0x28, green: 0x2a, blue: 0x36),
                foreground: ContentThemeColor(red: 0xf8, green: 0xf8, blue: 0xf2),
                muted: ContentThemeColor(red: 0x62, green: 0x72, blue: 0xa4),
                accent: ContentThemeColor(red: 0xbd, green: 0x93, blue: 0xf9),
                link: ContentThemeColor(red: 0x8b, green: 0xe9, blue: 0xfd),
                blockquote: ContentThemeColor(red: 0xf1, green: 0xfa, blue: 0x8c),
                codeBackground: ContentThemeColor(red: 0x34, green: 0x37, blue: 0x46)
            )
        }
        return ContentThemePalette(
            isDark: false,
            background: ContentThemeColor(red: 0xf8, green: 0xf8, blue: 0xf2),
            foreground: ContentThemeColor(red: 0x28, green: 0x2a, blue: 0x36),
            muted: ContentThemeColor(red: 0x62, green: 0x72, blue: 0xa4),
            accent: ContentThemeColor(red: 0x7c, green: 0x4d, blue: 0xbe),
            link: ContentThemeColor(red: 0x00, green: 0x6a, blue: 0x83),
            blockquote: ContentThemeColor(red: 0x5a, green: 0x3d, blue: 0x00),
            codeBackground: ContentThemeColor(red: 0xec, green: 0xec, blue: 0xf0)
        )
    }

    public func usesDarkPalette(effectiveDarkAppearance: Bool) -> Bool {
        palette(effectiveDarkAppearance: effectiveDarkAppearance).isDark
    }

    public func css(effectiveDarkAppearance: Bool) -> String {
        let palette = palette(effectiveDarkAppearance: effectiveDarkAppearance)
        let appearanceCSS = """
        :root { color-scheme: \(palette.isDark ? "dark" : "light"); --background: \(palette.background.cssHex); --foreground: \(palette.foreground.cssHex); --muted: \(palette.muted.cssHex); --accent: \(palette.accent.cssHex); }
        body { color: var(--foreground); background: var(--background); }
        a { color: \(palette.link.cssHex); } blockquote { border-color: var(--accent); color: \(palette.blockquote.cssHex); }
        pre, code { background: \(palette.codeBackground.cssHex); } .details { background: \(palette.codeBackground.cssHex) !important; }
        """

        let semanticCSS = semanticPalette.map {
            $0.variableCSS + "\n" + Self.semanticThemeCSS
        } ?? ""

        // Print rules must follow appearance rules in the cascade so dark screen
        // colors cannot win when WebKit switches to print media.
        return HTMLDocumentStreamRenderer.defaultThemeCSS
            + "\n" + appearanceCSS
            + "\n" + semanticCSS
            + "\n" + HTMLDocumentStreamRenderer.printThemeCSS
    }

    /// One selector contract shared by every semantic theme. Adding another theme is
    /// deliberately a palette-only operation; capsule markup and CSS targets stay fixed.
    private static let semanticThemeCSS = """
    ::selection { color: var(--theme-foreground); background: var(--theme-selection); }
    h1, h2, h3 { color: var(--theme-heading); }
    a { color: var(--theme-link); }
    a:hover, a:focus { color: var(--theme-link-hover); }
    a:focus-visible { outline: 2px solid var(--theme-heading); outline-offset: 2px; }
    strong { color: var(--theme-strong); }
    em { color: var(--theme-emphasis); }
    code { color: var(--theme-code); }
    pre, code { background: var(--theme-surface); }
    .browser-generated .details { background: var(--theme-surface) !important; }
    .delimiter, .link-hint { color: var(--theme-muted); }
    .list-item > span[aria-hidden="true"] { color: var(--theme-accent); }
    blockquote {
      color: var(--theme-foreground); border-color: var(--theme-muted);
      background: var(--theme-surface); border-radius: 0 .4rem .4rem 0;
    }
    .pre-block.multiline[open] > pre:focus-visible { outline-color: var(--theme-heading); }
    .pre-block > summary, figcaption, .browser-generated .eyebrow,
    .source-line::before { color: var(--theme-muted); }
    .source-line:hover { background: var(--theme-surface); }
    .incomplete { border-color: var(--theme-strong); }
    .browser-generated h1 { color: var(--theme-danger); }
    @media print {
      h1, h2, h3, strong, em, .delimiter, .link-hint,
      .list-item > span[aria-hidden="true"], .browser-generated h1 {
        color: #000 !important;
      }
      blockquote { background: transparent !important; }
      .browser-generated .eyebrow, .source-line::before { color: #444 !important; }
      .source-line:hover { background: transparent !important; }
      .incomplete { border-color: #777 !important; }
    }
    """

    var semanticPalette: SemanticContentThemePalette? {
        switch self {
        case .draculaClassic:
            SemanticContentThemePalette(
                isDark: true,
                background: 0x282a36, surface: 0x343746, foreground: 0xf8f8f2,
                muted: 0x6272a4, heading: 0xbd93f9, link: 0x8be9fd,
                linkHover: 0xff79c6, accent: 0xff79c6, strong: 0xffb86c,
                emphasis: 0xf1fa8c, code: 0x50fa7b, danger: 0xff5555,
                selection: 0x44475a
            )
        case .ocean:
            SemanticContentThemePalette(
                isDark: true,
                background: 0x071a2b, surface: 0x102b3f, foreground: 0xeaf7fa,
                muted: 0x9bb8c3, heading: 0x38d6c8, link: 0x69c7ff,
                linkHover: 0xff9b73, accent: 0xff9b73, strong: 0xffb86b,
                emphasis: 0xffdca8, code: 0x70e1c8, danger: 0xff6b6b,
                selection: 0x16465c
            )
        case .forest:
            SemanticContentThemePalette(
                isDark: true,
                background: 0x2b3d29, surface: 0x3a5a3c, foreground: 0xf2f5ed,
                muted: 0xa9d6bb, heading: 0xc3e7d2, link: 0xa9d6bb,
                linkHover: 0xf2d49b, accent: 0x6a9a6d, strong: 0xf2d49b,
                emphasis: 0xd7e8a3, code: 0xb9e2c9, danger: 0xff8b7d,
                selection: 0x477747
            )
        case .creamsicle:
            SemanticContentThemePalette(
                isDark: false,
                background: 0xfff7ed, surface: 0xffcc80, foreground: 0x43200d,
                muted: 0x76523e, heading: 0xc2410c, link: 0x006477,
                linkHover: 0x9a3412, accent: 0xff8c00, strong: 0xa83a0b,
                emphasis: 0x7c4a03, code: 0x00675b, danger: 0xb42318,
                selection: 0xffad42
            )
        case .sandDunes:
            SemanticContentThemePalette(
                isDark: false,
                background: 0xf6e7c8, surface: 0xe8cf9f, foreground: 0x34281d,
                muted: 0x6e5b47, heading: 0xa84e32, link: 0x006b6b,
                linkHover: 0x7b3e24, accent: 0xc66a42, strong: 0x8b451f,
                emphasis: 0x6d5a00, code: 0x27624c, danger: 0xa83232,
                selection: 0xdabf8d
            )
        case .draculaLight, .draculaDark:
            nil
        }
    }

    /// Older preferences stored an appearance-following theme. Preserve every other
    /// preference while moving those installations to the new fixed default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "automatic" {
            self = .draculaDark
        } else if let theme = Self(rawValue: value) {
            self = theme
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown content theme: \(value)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct SemanticContentThemePalette {
    let isDark: Bool
    let background: ContentThemeColor
    let surface: ContentThemeColor
    let foreground: ContentThemeColor
    let muted: ContentThemeColor
    let heading: ContentThemeColor
    let link: ContentThemeColor
    let linkHover: ContentThemeColor
    let accent: ContentThemeColor
    let strong: ContentThemeColor
    let emphasis: ContentThemeColor
    let code: ContentThemeColor
    let danger: ContentThemeColor
    let selection: ContentThemeColor

    init(
        isDark: Bool,
        background: UInt32, surface: UInt32, foreground: UInt32, muted: UInt32,
        heading: UInt32, link: UInt32, linkHover: UInt32, accent: UInt32,
        strong: UInt32, emphasis: UInt32, code: UInt32, danger: UInt32,
        selection: UInt32
    ) {
        self.isDark = isDark
        self.background = ContentThemeColor(hex: background)
        self.surface = ContentThemeColor(hex: surface)
        self.foreground = ContentThemeColor(hex: foreground)
        self.muted = ContentThemeColor(hex: muted)
        self.heading = ContentThemeColor(hex: heading)
        self.link = ContentThemeColor(hex: link)
        self.linkHover = ContentThemeColor(hex: linkHover)
        self.accent = ContentThemeColor(hex: accent)
        self.strong = ContentThemeColor(hex: strong)
        self.emphasis = ContentThemeColor(hex: emphasis)
        self.code = ContentThemeColor(hex: code)
        self.danger = ContentThemeColor(hex: danger)
        self.selection = ContentThemeColor(hex: selection)
    }

    var contentPalette: ContentThemePalette {
        ContentThemePalette(
            isDark: isDark,
            background: background,
            foreground: foreground,
            muted: muted,
            accent: accent,
            link: link,
            blockquote: foreground,
            codeBackground: surface
        )
    }

    var variableCSS: String {
        """
        :root {
          --theme-background: \(background.cssHex); --theme-surface: \(surface.cssHex);
          --theme-foreground: \(foreground.cssHex); --theme-muted: \(muted.cssHex);
          --theme-heading: \(heading.cssHex); --theme-link: \(link.cssHex);
          --theme-link-hover: \(linkHover.cssHex); --theme-accent: \(accent.cssHex);
          --theme-strong: \(strong.cssHex); --theme-emphasis: \(emphasis.cssHex);
          --theme-code: \(code.cssHex); --theme-danger: \(danger.cssHex);
          --theme-selection: \(selection.cssHex);
        }
        """
    }
}

private extension ContentThemeColor {
    init(hex: UInt32) {
        self.init(
            red: UInt8((hex >> 16) & 0xff),
            green: UInt8((hex >> 8) & 0xff),
            blue: UInt8(hex & 0xff)
        )
    }
}

public struct GeminiProxyConfiguration: Equatable, Codable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct BrowserPreferences: Equatable, Codable, Sendable {
    public var homepage: String
    public var searchProvider: SearchProvider
    public var customSearchEndpoint: String
    public var applicationAppearance: ApplicationAppearance
    public var contentTheme: ContentTheme
    public var contentWidth: ContentWidth
    public var proxy: GeminiProxyConfiguration?
    public var automaticallyLoadsSameCapsuleImages: Bool
    public var automaticallyLoadsDataImages: Bool
    public var renderingOptions: HTMLRenderingOptions
    /// Shows each capsule's `favicon.txt` emoji beside its address and on its tab.
    public var showsFavicons: Bool
    /// Shows the Favourites bar under the toolbar.
    public var showsFavoritesBar: Bool

    public init(
        homepage: String = "gemini://gemi.dev/major-tom/",
        searchProvider: SearchProvider = .kennedy,
        customSearchEndpoint: String = "",
        applicationAppearance: ApplicationAppearance = .system,
        contentTheme: ContentTheme = .draculaDark,
        contentWidth: ContentWidth = .narrow,
        proxy: GeminiProxyConfiguration? = nil,
        automaticallyLoadsSameCapsuleImages: Bool = false,
        automaticallyLoadsDataImages: Bool = true,
        renderingOptions: HTMLRenderingOptions = HTMLRenderingOptions(),
        showsFavicons: Bool = true,
        showsFavoritesBar: Bool = false
    ) {
        self.homepage = homepage
        self.searchProvider = searchProvider
        self.customSearchEndpoint = customSearchEndpoint
        self.applicationAppearance = applicationAppearance
        self.contentTheme = contentTheme
        self.contentWidth = contentWidth
        self.proxy = proxy
        self.automaticallyLoadsSameCapsuleImages = automaticallyLoadsSameCapsuleImages
        self.automaticallyLoadsDataImages = automaticallyLoadsDataImages
        self.renderingOptions = renderingOptions
        self.showsFavicons = showsFavicons
        self.showsFavoritesBar = showsFavoritesBar
    }

    /// Decodes leniently, key by key, so that adding a preference cannot discard the
    /// ones already stored.
    ///
    /// The synthesized decoder throws when a key it expects is missing, and the settings
    /// store loads with `try?` — so before this existed, shipping one new preference
    /// would silently reset the homepage, search provider, proxy and themes back to
    /// their defaults for everyone who already had settings saved.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrowserPreferences()
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
            ?? defaults.homepage
        searchProvider = try container.decodeIfPresent(SearchProvider.self, forKey: .searchProvider)
            ?? defaults.searchProvider
        customSearchEndpoint = try container.decodeIfPresent(String.self, forKey: .customSearchEndpoint)
            ?? defaults.customSearchEndpoint
        applicationAppearance = try container.decodeIfPresent(
            ApplicationAppearance.self,
            forKey: .applicationAppearance
        ) ?? defaults.applicationAppearance
        contentTheme = try container.decodeIfPresent(ContentTheme.self, forKey: .contentTheme)
            ?? defaults.contentTheme
        contentWidth = try container.decodeIfPresent(ContentWidth.self, forKey: .contentWidth)
            ?? defaults.contentWidth
        // Genuinely optional: absent and "no proxy" are the same thing.
        proxy = try container.decodeIfPresent(GeminiProxyConfiguration.self, forKey: .proxy)
        automaticallyLoadsSameCapsuleImages = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyLoadsSameCapsuleImages
        ) ?? defaults.automaticallyLoadsSameCapsuleImages
        automaticallyLoadsDataImages = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyLoadsDataImages
        ) ?? defaults.automaticallyLoadsDataImages
        renderingOptions = try container.decodeIfPresent(
            HTMLRenderingOptions.self,
            forKey: .renderingOptions
        ) ?? defaults.renderingOptions
        showsFavicons = try container.decodeIfPresent(Bool.self, forKey: .showsFavicons)
            ?? defaults.showsFavicons
        showsFavoritesBar = try container.decodeIfPresent(Bool.self, forKey: .showsFavoritesBar)
            ?? defaults.showsFavoritesBar
    }
}
