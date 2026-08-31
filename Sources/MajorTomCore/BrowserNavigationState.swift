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

/// One tab's durable navigation state, as written to and read from a saved session.
public struct RestoredTabState: Codable, Equatable, Sendable {
    public var history: [URL]
    public var historyIndex: Int
    public var cachedPages: [CachedPage]
    public var zoom: Double
    public var title: String?
    public var documentTitle: String?

    public init(
        history: [URL],
        historyIndex: Int,
        cachedPages: [CachedPage],
        zoom: Double,
        title: String? = nil,
        documentTitle: String? = nil
    ) {
        self.history = history
        self.historyIndex = historyIndex
        self.cachedPages = cachedPages
        self.zoom = zoom
        self.title = title
        self.documentTitle = documentTitle
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

    public private(set) var history: [URL] = []
    /// Index into `history`, or -1 when nothing has been committed.
    public private(set) var historyIndex: Int = -1
    public private(set) var cachedPages: [URL: CachedPage] = [:]

    /// Reading positions keyed by history entry rather than by URL, so two visits to one
    /// address can hold different positions. Deliberately not persisted: quitting starts
    /// every entry back at the top.
    private var scrollOffsets: [Int: Double] = [:]
    private let cacheByteBudget: Int

    public init(cacheByteBudget: Int = NavigationState.defaultCacheByteBudget) {
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
        self.cacheByteBudget = cacheByteBudget
        history = state.history
        historyIndex = state.history.isEmpty
            ? -1
            : min(max(state.historyIndex, 0), state.history.count - 1)
        cachedPages = Dictionary(
            state.cachedPages.map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Position

    public var committedURL: URL? {
        history.indices.contains(historyIndex) ? history[historyIndex] : nil
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
            if historyIndex + 1 < history.count {
                history.removeSubrange((historyIndex + 1)...)
                scrollOffsets = scrollOffsets.filter { $0.key <= historyIndex }
            }
            // Re-committing the entry already at the cursor is not a new entry. Following
            // a link back to the page you are on should not grow the history.
            guard history.last != url else { return false }
            history.append(url)
            historyIndex = history.count - 1
            scrollOffsets[historyIndex] = 0
            return true
        }
    }

    /// Steps the cursor back one entry.
    ///
    /// - Returns: the entry now current, or nil when there is nothing behind the cursor.
    public mutating func goBack() -> URL? {
        guard canGoBack else { return nil }
        historyIndex -= 1
        return history[historyIndex]
    }

    /// Steps the cursor forward one entry.
    public mutating func goForward() -> URL? {
        guard canGoForward else { return nil }
        historyIndex += 1
        return history[historyIndex]
    }

    // MARK: - Reading position

    /// The offset saved for the entry the cursor is on.
    public var scrollOffset: Double { scrollOffsets[historyIndex] ?? 0 }

    public func scrollOffset(forHistoryIndex index: Int) -> Double {
        scrollOffsets[index] ?? 0
    }

    /// Records how far down the current entry the reader has scrolled.
    public mutating func recordScrollOffset(_ offset: Double) {
        guard history.indices.contains(historyIndex) else { return }
        scrollOffsets[historyIndex] = max(0, offset)
    }

    // MARK: - Cache

    public func cachedPage(for url: URL) -> CachedPage? { cachedPages[url] }

    /// Stores a representation, evicting the least recently received pages if the tab is
    /// now over budget. The entry for the page on screen is never evicted: reload and the
    /// content-theme re-render both read it back.
    public mutating func cache(_ page: CachedPage) {
        cachedPages[page.url] = page
        evictIfOverBudget()
    }

    public mutating func removeCachedPage(for url: URL) {
        cachedPages.removeValue(forKey: url)
    }

    public var cachedByteCount: Int {
        cachedPages.values.reduce(0) { $0 + $1.body.count }
    }

    private mutating func evictIfOverBudget() {
        var total = cachedByteCount
        guard total > cacheByteBudget else { return }
        let protectedURL = committedURL
        let candidates = cachedPages.values
            .filter { $0.url != protectedURL }
            .sorted { $0.receivedAt < $1.receivedAt }
        for candidate in candidates {
            guard total > cacheByteBudget else { break }
            cachedPages.removeValue(forKey: candidate.url)
            total -= candidate.body.count
        }
    }

    // MARK: - Session

    public func restorationState(
        zoom: Double,
        title: String?,
        documentTitle: String?
    ) -> RestoredTabState {
        RestoredTabState(
            history: history,
            historyIndex: historyIndex,
            cachedPages: Array(cachedPages.values),
            zoom: zoom,
            title: title,
            documentTitle: documentTitle
        )
    }
}
