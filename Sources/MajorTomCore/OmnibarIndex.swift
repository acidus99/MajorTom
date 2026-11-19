import Foundation

public struct OmnibarTab: Sendable {
    public let id: UUID
    public let url: URL
    public let title: String

    public init(id: UUID, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

public struct OmnibarDestination: Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let url: URL
    public var title: String
    public var isBookmark = false
    public var isFavorite = false
    public var visitedAt: Date?
    public var visitCount = 0
    public var tabID: UUID?
}

public struct OmnibarMatches: Sendable {
    public let destinations: [OmnibarDestination]
    /// Includes the user's prefix. The field selects only the appended suffix.
    public let completion: String?
    public let completedDestination: OmnibarDestination?
}

/// Immutable, prepared once per source revision and shared by all address fields.
/// Matching never reads persistence, fetches a favicon, or contacts a capsule.
public struct OmnibarIndex: Sendable {
    /// Owns a newly created immutable NSString, never a caller's mutable subclass.
    /// Foundation's literal UTF-16 search avoids repeating Unicode collation work
    /// for every prepared entry. There is no mutation or exposed reference.
    private final class LiteralText: @unchecked Sendable {
        private let value: NSString

        init(_ text: String) { value = NSString(string: text) }

        func contains(_ token: String) -> Bool {
            value.range(of: token, options: .literal).location != NSNotFound
        }

    }

    private struct Entry: Sendable {
        let destination: OmnibarDestination
        let tabIDs: [UUID]
        let address: String
        let host: String
        let key: String
        let searchable: LiteralText
        let wordPrefixes: LiteralText
        let usage: Double

        func destination(excludingTabID currentTabID: UUID?) -> OmnibarDestination {
            var result = destination
            result.tabID = tabIDs.first { $0 != currentTabID }
            return result
        }
    }

    private let entries: [Entry]

    public init(history: [BrowsingHistoryEntry], bookmarks: BookmarkCollection, tabs: [OmnibarTab]) {
        var destinations: [String: OmnibarDestination] = [:]
        var tabIDsByURL: [String: [UUID]] = [:]
        for visit in history {
            var destination = OmnibarDestination(url: visit.url, title: visit.title)
            destination.visitedAt = visit.visitedAt
            destination.visitCount = visit.visitCount
            destinations[destination.id] = destination
        }
        for (folderIndex, folder) in bookmarks.folders.enumerated() {
            for bookmark in folder.bookmarks {
                let key = bookmark.url.absoluteString
                var destination = destinations[key]
                    ?? OmnibarDestination(url: bookmark.url, title: bookmark.title)
                destination.isBookmark = true
                destination.isFavorite = destination.isFavorite || folderIndex == 0
                if !bookmark.title.isEmpty { destination.title = bookmark.title }
                destinations[key] = destination
            }
        }
        // Retain every tab so each field can choose a deterministic other tab,
        // including when the current destination is open in several windows.
        for tab in tabs.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let key = tab.url.absoluteString
            tabIDsByURL[key, default: []].append(tab.id)
            var destination = destinations[key] ?? OmnibarDestination(url: tab.url, title: tab.title)
            if destination.tabID == nil { destination.tabID = tab.id }
            if !destination.isBookmark && !tab.title.isEmpty { destination.title = tab.title }
            destinations[key] = destination
        }
        entries = destinations.values.map { destination in
            let address = Self.fold(destination.url.absoluteString)
            let title = Self.fold(destination.title)
            let words = (title + " " + address).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return Entry(
                destination: destination,
                tabIDs: tabIDsByURL[destination.id] ?? [],
                address: address,
                host: Self.fold(destination.url.host ?? ""),
                key: destination.id,
                searchable: LiteralText(title + "\n" + address),
                wordPrefixes: LiteralText(" " + words.joined(separator: " ")),
                usage: 0.7 * min(6, log2(Double(max(0, destination.visitCount)) + 1))
                    + (destination.isBookmark ? 1 : 0) + (destination.isFavorite ? 0.5 : 0)
            )
        }
    }

    public func search(_ input: String, excludingTabID currentTabID: UUID? = nil,
                       now: Date = Date(), limit: Int = 7) -> OmnibarMatches {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = Self.fold(value)
        let geminiPrefix = "gemini://" + query
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let wordQueries = tokens.map { " " + $0 }
        if tokens.isEmpty {
            let recent = entries.filter { $0.destination.isFavorite || $0.destination.visitedAt != nil }
                .sorted {
                    if $0.destination.isFavorite != $1.destination.isFavorite { return $0.destination.isFavorite }
                    if $0.destination.visitedAt != $1.destination.visitedAt {
                        return ($0.destination.visitedAt ?? .distantPast) > ($1.destination.visitedAt ?? .distantPast)
                    }
                    return $0.destination.id < $1.destination.id
                }
            return OmnibarMatches(
                destinations: recent.prefix(6).map { $0.destination(excludingTabID: currentTabID) },
                completion: nil, completedDestination: nil
            )
        }

        // Maintain only the best few results rather than sorting the full history.
        var best: [(entry: Entry, tier: Int, score: Double)] = []
        var bestCompletion: (entry: Entry, tier: Int, score: Double, text: String)?
        for entry in entries {
            if Task.isCancelled { break }
            let destination = entry.destination(excludingTabID: currentTabID)
            guard destination.tabID != nil || destination.isBookmark || destination.visitedAt != nil else { continue }
            guard tokens.allSatisfy({ entry.searchable.contains($0) }) else { continue }
            let tier: Int
            if entry.address == query || entry.host == query { tier = 0 }
            else if entry.host.hasPrefix(query) || entry.address.hasPrefix(query)
                || entry.address.hasPrefix(geminiPrefix) { tier = 1 }
            else if wordQueries.allSatisfy({ entry.wordPrefixes.contains($0) }) { tier = 2 }
            else { tier = 3 }
            let age = max(0, now.timeIntervalSince(destination.visitedAt ?? .distantPast)) / 86_400
            let score = 6 * exp(-age / 30) + entry.usage
            let candidate = (entry: entry, tier: tier, score: score)
            if limit > 0, best.count < limit || best.last.map({ Self.precedes(candidate, $0) }) == true {
                let insertion = best.firstIndex { Self.precedes(candidate, $0) } ?? best.count
                best.insert(candidate, at: insertion)
                if best.count > limit { best.removeLast() }
            }
            if tier <= 1, let completion = Self.completion(for: destination, input: value),
               bestCompletion == nil || Self.precedes(candidate, (bestCompletion!.entry, bestCompletion!.tier, bestCompletion!.score)) {
                bestCompletion = (entry, tier, score, completion)
            }
        }
        return OmnibarMatches(
            destinations: best.map { $0.entry.destination(excludingTabID: currentTabID) },
            completion: bestCompletion?.text,
            completedDestination: bestCompletion?.entry.destination(excludingTabID: currentTabID)
        )
    }

    private static func precedes(_ lhs: (entry: Entry, tier: Int, score: Double), _ rhs: (entry: Entry, tier: Int, score: Double)) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.entry.key < rhs.entry.key
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func completion(for destination: OmnibarDestination, input: String) -> String? {
        guard destination.visitedAt != nil || destination.isBookmark,
              destination.url.scheme?.lowercased() == "gemini",
              !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        let explicitScheme = input.contains("://")
        let address = destination.url.absoluteString
        let candidate = explicitScheme ? address : String(address.dropFirst("gemini://".count))
        guard candidate.count > input.count else { return nil }
        let prefix = String(candidate.prefix(input.count))
        // Hostnames are case insensitive; URL paths and queries are not. Folding the
        // whole prefix could silently change the destination of an explicitly typed path.
        let authorityStart = explicitScheme ? (input.range(of: "://")?.upperBound ?? input.startIndex) : input.startIndex
        let tailStart = input[authorityStart...].firstIndex(where: { "/?#".contains($0) }) ?? input.endIndex
        let authorityLength = input.distance(from: input.startIndex, to: tailStart)
        guard prefix.prefix(authorityLength).lowercased() == input.prefix(authorityLength).lowercased(),
              prefix.dropFirst(authorityLength) == input.dropFirst(authorityLength) else { return nil }
        return input + candidate.dropFirst(input.count)
    }
}
