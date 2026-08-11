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
    case automatic
    case draculaLight
    case draculaDark
    case draculaClassic

    public func palette(effectiveDarkAppearance: Bool) -> ContentThemePalette {
        let useDarkPalette: Bool
        switch self {
        case .automatic: useDarkPalette = effectiveDarkAppearance
        case .draculaLight: useDarkPalette = false
        case .draculaDark, .draculaClassic: useDarkPalette = true
        }

        if useDarkPalette {
            return ContentThemePalette(
                isDark: true,
                background: ContentThemeColor(red: 0x28, green: 0x2a, blue: 0x36),
                foreground: ContentThemeColor(red: 0xf8, green: 0xf8, blue: 0xf2),
                muted: ContentThemeColor(red: 0x62, green: 0x72, blue: 0xa4),
                accent: ContentThemeColor(red: 0xbd, green: 0x93, blue: 0xf9),
                link: ContentThemeColor(red: 0x8b, green: 0xe9, blue: 0xfd),
                blockquote: self == .draculaClassic
                    ? ContentThemeColor(red: 0xf8, green: 0xf8, blue: 0xf2)
                    : ContentThemeColor(red: 0xf1, green: 0xfa, blue: 0x8c),
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

        let semanticCSS = self == .draculaClassic ? Self.draculaClassicCSS : ""

        // Print rules must follow appearance rules in the cascade so dark screen
        // colors cannot win when WebKit switches to print media.
        return HTMLDocumentStreamRenderer.defaultThemeCSS
            + "\n" + appearanceCSS
            + "\n" + semanticCSS
            + "\n" + HTMLDocumentStreamRenderer.printThemeCSS
    }

    /// Dracula CSS's prose-oriented semantic mapping, adapted to Major Tom's
    /// streamed Gemtext markup. Ordinary prose stays neutral while structure,
    /// inline emphasis and interaction states receive stable roles.
    private static let draculaClassicCSS = """
    :root {
      --selection: #44475a; --surface-dark: #21222c; --surface-light: #343746;
      --red: #ff5555; --orange: #ffb86c; --yellow: #f1fa8c;
      --green: #50fa7b; --purple: #bd93f9; --cyan: #8be9fd; --pink: #ff79c6;
    }
    ::selection { color: var(--foreground); background: var(--selection); }
    h1, h2, h3 { color: var(--purple); }
    a { color: var(--cyan); }
    a:hover, a:focus { color: var(--pink); }
    a:focus-visible { outline: 2px solid var(--purple); outline-offset: 2px; }
    strong { color: var(--orange); }
    em { color: var(--yellow); }
    code { color: var(--green); }
    pre, code { background: var(--surface-light); }
    .browser-generated .details { background: var(--surface-light) !important; }
    .delimiter, .link-hint { color: var(--muted); }
    .list-item > span[aria-hidden="true"] { color: var(--pink); }
    blockquote {
      color: var(--foreground); border-color: var(--muted);
      background: var(--surface-dark); border-radius: 0 .4rem .4rem 0;
    }
    .pre-block.multiline[open] > pre:focus-visible { outline-color: var(--purple); }
    .pre-block > summary, figcaption, .browser-generated .eyebrow,
    .source-line::before { color: var(--muted); }
    .source-line:hover { background: var(--surface-dark); }
    .incomplete { border-color: var(--orange); }
    .browser-generated h1 { color: var(--red); }
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
        homepage: String = "gemini://gemi.dev/",
        searchProvider: SearchProvider = .kennedy,
        customSearchEndpoint: String = "",
        applicationAppearance: ApplicationAppearance = .system,
        contentTheme: ContentTheme = .automatic,
        contentWidth: ContentWidth = .narrow,
        proxy: GeminiProxyConfiguration? = nil,
        automaticallyLoadsSameCapsuleImages: Bool = true,
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
