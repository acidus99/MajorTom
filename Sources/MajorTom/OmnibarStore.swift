import Combine
import Foundation
import MajorTomCore

extension Notification.Name {
    static let majorTomOmnibarTabsChanged = Notification.Name("majorTomOmnibarTabsChanged")
    static let majorTomSelectOmnibar = Notification.Name("majorTomSelectOmnibar")
}

/// Source stores stay authoritative. This disposable index owns no browsing data.
@MainActor
final class OmnibarStore: ObservableObject {
    @Published private(set) var revision = 0
    private var indexTask: Task<OmnibarIndex, Never>?
    private var observations: Set<AnyCancellable> = []

    init(history: BrowsingHistoryStore, bookmarks: BookmarksModel) {
        history.$records
            .combineLatest(bookmarks.$collection)
            .sink { [weak self] history, bookmarks in
                self?.rebuild(history: history, bookmarks: bookmarks)
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: .majorTomOmnibarTabsChanged)
            .sink { [weak self] _ in
                self?.rebuild(
                    history: history.records,
                    bookmarks: bookmarks.collection
                )
            }
            .store(in: &observations)
    }

    private func rebuild(history: [BrowsingHistoryEntry], bookmarks: BookmarkCollection) {
        let tabs = NativeTabCoordinator.shared.omnibarTabs
        indexTask?.cancel()
        indexTask = Task.detached(priority: .userInitiated) {
            OmnibarIndex(history: history, bookmarks: bookmarks, tabs: tabs)
        }
        revision += 1
    }

    func search(_ input: String, excludingTabID currentTabID: UUID?) async -> OmnibarMatches? {
        guard let index = await indexTask?.value, !Task.isCancelled else { return nil }
        let task = Task.detached(priority: .userInitiated) { index.search(input, excludingTabID: currentTabID) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
