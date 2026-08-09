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

    public func palette(effectiveDarkAppearance: Bool) -> ContentThemePalette {
        let useDarkPalette: Bool
        switch self {
        case .automatic: useDarkPalette = effectiveDarkAppearance
        case .draculaLight: useDarkPalette = false
        case .draculaDark: useDarkPalette = true
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

        // Print rules must follow appearance rules in the cascade so dark screen
        // colors cannot win when WebKit switches to print media.
        return HTMLDocumentStreamRenderer.defaultThemeCSS
            + "\n" + appearanceCSS
            + "\n" + HTMLDocumentStreamRenderer.printThemeCSS
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
