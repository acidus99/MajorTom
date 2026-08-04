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

public enum ContentTheme: String, CaseIterable, Codable, Sendable {
    case automatic
    case draculaLight
    case draculaDark

    public func css(effectiveDarkAppearance: Bool) -> String {
        let dark = self == .draculaDark || (self == .automatic && effectiveDarkAppearance)
        let appearanceCSS: String
        if dark {
            appearanceCSS = """
            :root { color-scheme: dark; --background: #282a36; --foreground: #f8f8f2; --muted: #6272a4; --accent: #bd93f9; }
            body { color: var(--foreground); background: var(--background); }
            a { color: #8be9fd; } blockquote { border-color: var(--accent); color: #f1fa8c; }
            pre, code { background: #343746; } .details { background: #343746 !important; }
            """
        } else {
            appearanceCSS = """
            :root { color-scheme: light; --background: #f8f8f2; --foreground: #282a36; --muted: #6272a4; --accent: #7c4dbe; }
            body { color: var(--foreground); background: var(--background); }
            a { color: #006a83; } blockquote { border-color: var(--accent); color: #5a3d00; }
            pre, code { background: #ececf0; } .details { background: #ececf0 !important; }
            """
        }

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
