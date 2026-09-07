import Foundation

/// Whether a stored representation is the whole response.
///
/// A response that was interrupted is still worth keeping and showing, but it must never
/// be mistaken for a complete one — Save Page As, View Source and the cache all depend on
/// the difference.
public enum PageCompletionState: String, Codable, Sendable {
    case complete
    case incomplete
    case stopped
    case failed
}

/// One page as it was received, kept so Back, Forward and reload can re-present it
/// without asking the capsule again.
public struct CachedPage: Codable, Equatable, Sendable {
    public var url: URL
    public var mimeType: String
    public var body: Data
    public var completion: PageCompletionState
    public var receivedAt: Date
    public var title: String?
    public var documentTitle: String?
    /// The Gemini response header that produced this representation. Optional so sessions
    /// written before these fields existed continue to decode.
    public var responseStatus: Int?
    public var responseMeta: String?
    /// Identity actually offered in the TLS handshake that produced this representation.
    public var clientCertificateID: UUID?

    public init(
        url: URL,
        mimeType: String,
        body: Data,
        completion: PageCompletionState,
        receivedAt: Date,
        title: String? = nil,
        documentTitle: String? = nil,
        responseStatus: Int? = nil,
        responseMeta: String? = nil,
        clientCertificateID: UUID? = nil
    ) {
        self.url = url
        self.mimeType = mimeType
        self.body = body
        self.completion = completion
        self.receivedAt = receivedAt
        self.title = title
        self.documentTitle = documentTitle
        self.responseStatus = responseStatus
        self.responseMeta = responseMeta
        self.clientCertificateID = clientCertificateID
    }
}

/// Browser-owned interaction state that belongs to one visit in a tab's Back/Forward list.
/// The response remains authoritative; this small envelope records only how the reader left it.
public struct HistoryPresentationState: Codable, Equatable, Sendable {
    public var version: Int
    public var scrollY: Double
    public var expandedImages: [URL]
    public var collapsedPreformatted: [Int]

    public init(
        version: Int = 1,
        scrollY: Double = 0,
        expandedImages: [URL] = [],
        collapsedPreformatted: [Int] = []
    ) {
        self.version = version
        self.scrollY = scrollY.isFinite ? max(0, scrollY) : 0
        self.expandedImages = Array(Set(expandedImages)).sorted { $0.absoluteString < $1.absoluteString }
        self.collapsedPreformatted = Array(Set(collapsedPreformatted.filter { $0 > 0 })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case version, scrollY, expandedImages, collapsedPreformatted
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try values.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            scrollY: try values.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0,
            expandedImages: try values.decodeIfPresent([URL].self, forKey: .expandedImages) ?? [],
            collapsedPreformatted: try values.decodeIfPresent([Int].self, forKey: .collapsedPreformatted) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(scrollY, forKey: .scrollY)
        try values.encode(expandedImages, forKey: .expandedImages)
        try values.encode(collapsedPreformatted, forKey: .collapsedPreformatted)
    }
}

/// One particular visit, not merely the latest response for a URL.
public struct BackForwardEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var url: URL
    public var title: String?
    public var favicon: String?
    public var page: CachedPage?
    public var presentation: HistoryPresentationState

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        favicon: String? = nil,
        page: CachedPage? = nil,
        presentation: HistoryPresentationState = HistoryPresentationState()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.favicon = favicon
        self.page = page
        self.presentation = presentation
    }
}

/// One tab's durable navigation state, as written to and read from a saved session.
public struct RestoredTabState: Codable, Equatable, Sendable {
    public var tabID: UUID
    public var entries: [BackForwardEntry]
    public var history: [URL]
    public var historyIndex: Int
    public var cachedPages: [CachedPage]
    public var zoom: Double
    public var title: String?
    public var documentTitle: String?
    /// Reading positions keyed by Back/Forward entry. Optional for sessions written by
    /// releases that deliberately reset every page to the top when the app quit.
    public var scrollOffsets: [Int: Double]?

    public init(
        tabID: UUID = UUID(),
        entries: [BackForwardEntry]? = nil,
        history: [URL],
        historyIndex: Int,
        cachedPages: [CachedPage],
        zoom: Double,
        title: String? = nil,
        documentTitle: String? = nil,
        scrollOffsets: [Int: Double]? = nil
    ) {
        self.tabID = tabID
        self.entries = entries ?? history.enumerated().map { index, url in
            let page = cachedPages.first { $0.url == url }
            return BackForwardEntry(
                url: url,
                title: page?.documentTitle ?? page?.title,
                page: page,
                presentation: HistoryPresentationState(scrollY: scrollOffsets?[index] ?? 0)
            )
        }
        self.history = history
        self.historyIndex = historyIndex
        self.cachedPages = cachedPages
        self.zoom = zoom
        self.title = title
        self.documentTitle = documentTitle
        self.scrollOffsets = scrollOffsets
    }

    private enum CodingKeys: String, CodingKey {
        case tabID, entries, history, historyIndex, cachedPages, zoom, title, documentTitle, scrollOffsets
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let history = try values.decodeIfPresent([URL].self, forKey: .history) ?? []
        let cachedPages = try values.decodeIfPresent([CachedPage].self, forKey: .cachedPages) ?? []
        let scrollOffsets = try values.decodeIfPresent([Int: Double].self, forKey: .scrollOffsets)
        self.init(
            tabID: try values.decodeIfPresent(UUID.self, forKey: .tabID) ?? UUID(),
            entries: try values.decodeIfPresent([BackForwardEntry].self, forKey: .entries),
            history: history,
            historyIndex: try values.decodeIfPresent(Int.self, forKey: .historyIndex) ?? -1,
            cachedPages: cachedPages,
            zoom: try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1,
            title: try values.decodeIfPresent(String.self, forKey: .title),
            documentTitle: try values.decodeIfPresent(String.self, forKey: .documentTitle),
            scrollOffsets: scrollOffsets
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tabID, forKey: .tabID)
        try values.encode(entries, forKey: .entries)
        try values.encode(history, forKey: .history)
        try values.encode(historyIndex, forKey: .historyIndex)
        try values.encode(cachedPages, forKey: .cachedPages)
        try values.encode(zoom, forKey: .zoom)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(documentTitle, forKey: .documentTitle)
        try values.encodeIfPresent(scrollOffsets, forKey: .scrollOffsets)
    }
}

/// A tab's position in its own history, the pages it has kept, and where the reader had
/// scrolled to in each of them.
///
/// This is the part of a tab that is decidable without WebKit, AppKit or a network: given
/// a starting state and a sequence of commits and traversals, the resulting history,
/// cursor, cache and scroll offsets follow. It lives here rather than in the browser model
/// so those rules can be tested directly — the branching in `commit` and in restoration
/// has produced several bugs that were only ever found by hand.
///
/// It decides nothing about *how* to load a page. The model still owns the transport, the
/// trust prompts, the document stream and every piece of AppKit.
public struct NavigationState: Equatable, Sendable {
    /// How a commit relates to the entries already in the history.
    public enum Disposition: String, Equatable, Sendable {
        /// A new destination. Supersedes anything ahead of the cursor.
        case new
        /// The same entry again. Leaves the history untouched.
        case reload
        /// Moving to an entry that is already in the history.
        case traversal
    }

    /// Total size of cached bodies to keep per tab.
    ///
    /// A tab used to retain the full body of every page it had ever visited, for the life
    /// of the tab, with no bound and no eviction — and then serialised all of it into the
    /// saved session. One image-heavy capsule could account for more than every text page
    /// of a long session put together, so the budget is in bytes rather than entries.
    public static let defaultCacheByteBudget = 32 * 1_024 * 1_024

    public let tabID: UUID
    public private(set) var entries: [BackForwardEntry] = []
    public var history: [URL] { entries.map(\.url) }
    /// Index into `history`, or -1 when nothing has been committed.
    public private(set) var historyIndex: Int = -1
    public var cachedPages: [URL: CachedPage] {
        Dictionary(entries.compactMap { entry in entry.page.map { (entry.url, $0) } },
                   uniquingKeysWith: { _, newest in newest })
    }

    /// Reading positions keyed by history entry rather than by URL, so two visits to one
    /// address can hold different positions.
    private let cacheByteBudget: Int

    public init(tabID: UUID = UUID(), cacheByteBudget: Int = NavigationState.defaultCacheByteBudget) {
        self.tabID = tabID
        self.cacheByteBudget = cacheByteBudget
    }

    /// Rebuilds a tab from a saved session.
    ///
    /// The index is clamped at both ends. A negative or out-of-range value from an older
    /// or corrupted blob previously left `committedURL` nil, which silently discarded the
    /// entire restored history.
    public init(
        restoring state: RestoredTabState,
        cacheByteBudget: Int = NavigationState.defaultCacheByteBudget
    ) {
        tabID = state.tabID
        self.cacheByteBudget = cacheByteBudget
        entries = state.entries.isEmpty && !state.history.isEmpty
            ? state.history.enumerated().map { index, url in
                let page = state.cachedPages.first { $0.url == url }
                return BackForwardEntry(
                    url: url,
                    title: page?.documentTitle ?? page?.title,
                    page: page,
                    presentation: HistoryPresentationState(scrollY: state.scrollOffsets?[index] ?? 0)
                )
            }
            : state.entries
        historyIndex = entries.isEmpty
            ? -1
            : min(max(state.historyIndex, 0), entries.count - 1)
    }

    // MARK: - Position

    public var committedURL: URL? {
        entries.indices.contains(historyIndex) ? entries[historyIndex].url : nil
    }

    public var currentEntryID: UUID? {
        entries.indices.contains(historyIndex) ? entries[historyIndex].id : nil
    }

    public var currentEntry: BackForwardEntry? {
        entries.indices.contains(historyIndex) ? entries[historyIndex] : nil
    }

    public var canGoBack: Bool { historyIndex > 0 }

    public var canGoForward: Bool {
        historyIndex >= 0 && historyIndex + 1 < history.count
    }

    public var isEmpty: Bool { history.isEmpty }

    // MARK: - Moving

    /// Records that `url` is now the page on screen.
    ///
    /// - Returns: true when the history itself changed, so a caller can record the visit
    ///   only for a genuinely new destination.
    @discardableResult
    public mutating func commit(_ url: URL, disposition: Disposition) -> Bool {
        switch disposition {
        case .reload, .traversal:
            return false
        case .new:
            // A new destination supersedes the forward branch, and the offsets recorded
            // for the entries that branch contained.
            if historyIndex + 1 < entries.count {
                entries.removeSubrange((historyIndex + 1)...)
            }
            // Re-committing the entry already at the cursor is not a new entry. Following
            // a link back to the page you are on should not grow the history.
            guard entries.last?.url != url else { return false }
            entries.append(BackForwardEntry(url: url))
            historyIndex = entries.count - 1
            return true
        }
    }

    /// Steps the cursor back one entry.
    ///
    /// - Returns: the entry now current, or nil when there is nothing behind the cursor.
    public mutating func goBack() -> URL? {
        guard canGoBack else { return nil }
        historyIndex -= 1
        return entries[historyIndex].url
    }

    /// Steps the cursor forward one entry.
    public mutating func goForward() -> URL? {
        guard canGoForward else { return nil }
        historyIndex += 1
        return entries[historyIndex].url
    }

    // MARK: - Reading position

    /// The offset saved for the entry the cursor is on.
    public var scrollOffset: Double {
        entries.indices.contains(historyIndex) ? entries[historyIndex].presentation.scrollY : 0
    }

    public func scrollOffset(forHistoryIndex index: Int) -> Double {
        entries.indices.contains(index) ? entries[index].presentation.scrollY : 0
    }

    public func presentationState(forHistoryIndex index: Int) -> HistoryPresentationState? {
        entries.indices.contains(index) ? entries[index].presentation : nil
    }

    /// Records how far down the current entry the reader has scrolled.
    public mutating func recordScrollOffset(_ offset: Double) {
        guard entries.indices.contains(historyIndex), offset.isFinite else { return }
        entries[historyIndex].presentation.scrollY = max(0, offset)
    }

    public mutating func setImage(_ url: URL, expanded: Bool) {
        guard entries.indices.contains(historyIndex) else { return }
        var values = Set(entries[historyIndex].presentation.expandedImages)
        if expanded { values.insert(url) } else { values.remove(url) }
        entries[historyIndex].presentation.expandedImages = values.sorted { $0.absoluteString < $1.absoluteString }
    }

    public mutating func setPreformattedSection(_ index: Int, collapsed: Bool) {
        guard entries.indices.contains(historyIndex), index > 0 else { return }
        var values = Set(entries[historyIndex].presentation.collapsedPreformatted)
        if collapsed { values.insert(index) } else { values.remove(index) }
        entries[historyIndex].presentation.collapsedPreformatted = values.sorted()
    }

    public mutating func updateCurrentMetadata(title: String?, favicon: String?) {
        guard entries.indices.contains(historyIndex) else { return }
        entries[historyIndex].title = title
        entries[historyIndex].favicon = favicon
    }

    // MARK: - Cache

    public func cachedPage(for url: URL) -> CachedPage? {
        guard entries.indices.contains(historyIndex), entries[historyIndex].url == url else { return nil }
        return entries[historyIndex].page
    }

    /// Stores a representation, evicting the least recently received pages if the tab is
    /// now over budget. The entry for the page on screen is never evicted: reload and the
    /// content-theme re-render both read it back.
    public mutating func cache(_ page: CachedPage) {
        guard entries.indices.contains(historyIndex), entries[historyIndex].url == page.url else { return }
        entries[historyIndex].page = page
        entries[historyIndex].title = page.documentTitle ?? page.title
        evictIfOverBudget()
    }

    public mutating func cache(_ page: CachedPage, for entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].url == page.url else { return }
        entries[index].page = page
        entries[index].title = page.documentTitle ?? page.title
        evictIfOverBudget()
    }

    public mutating func removeCurrentCachedPage() {
        guard entries.indices.contains(historyIndex) else { return }
        entries[historyIndex].page = nil
    }

    public mutating func removeCachedPage(for url: URL) {
        for index in entries.indices where entries[index].url == url {
            entries[index].page = nil
        }
    }

    public var cachedByteCount: Int {
        entries.compactMap(\.page).reduce(0) { $0 + $1.body.count }
    }

    private mutating func evictIfOverBudget() {
        var total = cachedByteCount
        guard total > cacheByteBudget else { return }
        let candidates = entries.indices
            .filter { $0 != historyIndex && entries[$0].page != nil }
            .sorted { entries[$0].page!.receivedAt < entries[$1].page!.receivedAt }
        for index in candidates {
            guard total > cacheByteBudget else { break }
            total -= entries[index].page?.body.count ?? 0
            entries[index].page = nil
        }
    }

    // MARK: - Session

    public func restorationState(
        zoom: Double,
        title: String?,
        documentTitle: String?
    ) -> RestoredTabState {
        RestoredTabState(
            tabID: tabID,
            entries: entries,
            history: history,
            historyIndex: historyIndex,
            cachedPages: Array(cachedPages.values),
            zoom: zoom,
            title: title,
            documentTitle: documentTitle,
            scrollOffsets: Dictionary(uniqueKeysWithValues: entries.indices.map {
                ($0, entries[$0].presentation.scrollY)
            })
        )
    }
}
