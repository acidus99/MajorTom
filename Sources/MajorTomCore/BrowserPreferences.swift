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
        case .narrow: "calc(var(--reading-width) + 2 * var(--page-gutter))"
        case .wide: "calc(var(--wide-reading-width) + 2 * var(--page-gutter))"
        case .full: "none"
        }
        return """
        /* Explicit reading width applies to content pages rather than the image viewer. */
        @media screen {
          /* The reader's chosen width overrides the theme's content column. */
          body:not(.image-page) > main {
            max-width: \(maxWidth);
          }
        }
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

public enum SameCapsuleImageLoading: String, CaseIterable, Codable, Sendable {
    case off
    case whenVisible

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Former All selections retain automatic loading with the visible-link policy.
        if value == "all" { self = .whenVisible; return }
        guard let mode = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown image loading mode: \(value)")
        }
        self = mode
    }
}

public struct BrowserPreferences: Equatable, Codable, Sendable {
    public var homepage: String
    public var searchProvider: SearchProvider
    public var customSearchEndpoint: String
    public var applicationAppearance: ApplicationAppearance
    public var contentAppearance: ContentAppearance
    public var lightContentTheme: String
    public var darkContentTheme: String
    public var contentWidth: ContentWidth
    public var proxy: GeminiProxyConfiguration?
    public var sameCapsuleImageLoading: SameCapsuleImageLoading
    /// Compatibility with the former on/off preference and older sync clients.
    public var automaticallyLoadsSameCapsuleImages: Bool {
        get { sameCapsuleImageLoading != .off }
        set { sameCapsuleImageLoading = newValue ? .whenVisible : .off }
    }
    public var imageRequestInterval: TimeInterval
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
        contentAppearance: ContentAppearance = .dark,
        lightContentTheme: String = "draculaLight",
        darkContentTheme: String = "draculaDark",
        contentWidth: ContentWidth = .narrow,
        proxy: GeminiProxyConfiguration? = nil,
        automaticallyLoadsSameCapsuleImages: Bool = false,
        sameCapsuleImageLoading: SameCapsuleImageLoading? = nil,
        imageRequestInterval: TimeInterval = 2,
        automaticallyLoadsDataImages: Bool = true,
        renderingOptions: HTMLRenderingOptions = HTMLRenderingOptions(),
        showsFavicons: Bool = true,
        showsFavoritesBar: Bool = false
    ) {
        self.homepage = homepage
        self.searchProvider = searchProvider
        self.customSearchEndpoint = customSearchEndpoint
        self.applicationAppearance = applicationAppearance
        self.contentAppearance = contentAppearance
        self.lightContentTheme = lightContentTheme
        self.darkContentTheme = darkContentTheme
        self.contentWidth = contentWidth
        self.proxy = proxy
        self.sameCapsuleImageLoading = sameCapsuleImageLoading ?? (automaticallyLoadsSameCapsuleImages ? .whenVisible : .off)
        self.imageRequestInterval = imageRequestInterval
        self.automaticallyLoadsDataImages = automaticallyLoadsDataImages
        self.renderingOptions = renderingOptions
        self.showsFavicons = showsFavicons
        self.showsFavoritesBar = showsFavoritesBar
    }

    private enum LegacyCodingKeys: String, CodingKey { case contentTheme, automaticallyLoadsSameCapsuleImages }

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
        // Preserve a fixed theme's appearance when upgrading from the Swift palettes.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            .decodeIfPresent(String.self, forKey: .contentTheme)
        let legacyTheme = ContentTheme.bundled.first { $0.id == legacy }
        contentAppearance = try container.decodeIfPresent(ContentAppearance.self, forKey: .contentAppearance)
            ?? (legacyTheme?.appearance == .light ? .light : defaults.contentAppearance)
        lightContentTheme = try container.decodeIfPresent(String.self, forKey: .lightContentTheme)
            ?? (legacyTheme?.appearance == .light ? legacyTheme?.id : nil)
            ?? defaults.lightContentTheme
        darkContentTheme = try container.decodeIfPresent(String.self, forKey: .darkContentTheme)
            ?? (legacyTheme?.appearance == .dark ? legacyTheme?.id : nil)
            ?? defaults.darkContentTheme
        contentWidth = try container.decodeIfPresent(ContentWidth.self, forKey: .contentWidth)
            ?? defaults.contentWidth
        // Genuinely optional: absent and "no proxy" are the same thing.
        proxy = try container.decodeIfPresent(GeminiProxyConfiguration.self, forKey: .proxy)
        let legacyImages = try decoder.container(keyedBy: LegacyCodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .automaticallyLoadsSameCapsuleImages) ?? false
        sameCapsuleImageLoading = try container.decodeIfPresent(
            SameCapsuleImageLoading.self, forKey: .sameCapsuleImageLoading
        ) ?? (legacyImages ? .whenVisible : .off)
        imageRequestInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .imageRequestInterval)
            ?? defaults.imageRequestInterval
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
