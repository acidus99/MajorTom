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
        if dark {
            return HTMLDocumentStreamRenderer.defaultThemeCSS + """

            :root { color-scheme: dark; --background: #282a36; --foreground: #f8f8f2; --muted: #6272a4; --accent: #bd93f9; }
            body { color: var(--foreground); background: var(--background); }
            a { color: #8be9fd; } blockquote { border-color: var(--accent); color: #f1fa8c; }
            pre, code { background: #343746; } .details { background: #343746 !important; }
            """
        }
        return HTMLDocumentStreamRenderer.defaultThemeCSS + """

        :root { color-scheme: light; --background: #f8f8f2; --foreground: #282a36; --muted: #6272a4; --accent: #7c4dbe; }
        body { color: var(--foreground); background: var(--background); }
        a { color: #006a83; } blockquote { border-color: var(--accent); color: #5a3d00; }
        pre, code { background: #ececf0; } .details { background: #ececf0 !important; }
        """
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

    public init(
        homepage: String = "gemini://gemi.dev/",
        searchProvider: SearchProvider = .kennedy,
        customSearchEndpoint: String = "",
        applicationAppearance: ApplicationAppearance = .system,
        contentTheme: ContentTheme = .automatic,
        proxy: GeminiProxyConfiguration? = nil,
        automaticallyLoadsSameCapsuleImages: Bool = true,
        automaticallyLoadsDataImages: Bool = true,
        renderingOptions: HTMLRenderingOptions = HTMLRenderingOptions()
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
    }
}
