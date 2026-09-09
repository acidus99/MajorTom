import AppKit
import MajorTomCore
import SwiftUI

@available(macOS 26.0, *)
struct HistoryManagerView: View {
    let searchFocusRequest: Int
    let open: (URL) -> Void
    let openInNewTab: (URL) -> Void
    let openInNewWindow: (URL) -> Void

    @ObservedObject private var history = BrowsingHistoryStore.shared
    @State private var search = ""
    @State private var selection = Set<BrowsingHistoryEntry.ID>()
    @State private var sortOrder = [
        KeyPathComparator(\BrowsingHistoryEntry.visitedAt, order: .reverse)
    ]
    @State private var pendingDeletion = Set<BrowsingHistoryEntry.ID>()
    @State private var showsDeleteConfirmation = false
    @FocusState private var searchIsFocused: Bool

    private var visibleEntries: [BrowsingHistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = query.isEmpty ? history.records : history.records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.urlString.localizedCaseInsensitiveContains(query)
        }
        return entries.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: searchFocusRequest) { _, _ in searchIsFocused = true }
        .onChange(of: search) { _, _ in
            selection.formIntersection(visibleEntries.map(\.id))
        }
        .alert(
            pendingDeletion.count == 1 ? "Delete History Entry?" : "Delete History Entries?",
            isPresented: $showsDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion.removeAll() }
            Button("Delete", role: .destructive, action: deletePendingEntries)
        } message: {
            Text(pendingDeletion.count == 1
                ? "This entry will be removed from your browsing history."
                : "These \(pendingDeletion.count) entries will be removed from your browsing history.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer(minLength: 12)
            TextField("Search History", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($searchIsFocused)
                .accessibilityLabel("Search History")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var table: some View {
        Table(visibleEntries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { entry in
                Text(entry.title)
                    .lineLimit(1)
                    .help(entry.title)
            }
            .width(min: 160, ideal: 300)

            TableColumn("Last Visited", value: \.visitedAt) { entry in
                Text(entry.visitedAt, format: .dateTime.year().month().day().hour().minute())
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 190, max: 230)

            TableColumn("URL", value: \.urlString) { entry in
                Text(entry.urlString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.urlString)
            }
            .width(min: 220, ideal: 480)
        }
        .overlay {
            if visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "No History" : "No Results", systemImage: "clock")
                } description: {
                    Text(search.isEmpty
                        ? "Pages you visit will appear here."
                        : "No history entry matches your search.")
                }
            }
        }
        .contextMenu(forSelectionType: BrowsingHistoryEntry.ID.self) { identifiers in
            let entries = selectedEntries(for: identifiers)
            Button("Open in New Tab") {
                entries.forEach { openInNewTab($0.url) }
            }
            Button("Open in New Window") {
                entries.forEach { openInNewWindow($0.url) }
            }
            Divider()
            Button("Copy Link") { copyLinks(entries) }
            Divider()
            Button("Delete", role: .destructive) { requestDeletion(identifiers) }
        } primaryAction: { identifiers in
            guard let first = selectedEntries(for: identifiers).first else { return }
            open(first.url)
        }
        .onDeleteCommand { requestDeletion(selection) }
        .accessibilityLabel("Browsing History")
    }

    private func selectedEntries(
        for identifiers: Set<BrowsingHistoryEntry.ID>
    ) -> [BrowsingHistoryEntry] {
        visibleEntries.filter { identifiers.contains($0.id) }
    }

    private func copyLinks(_ entries: [BrowsingHistoryEntry]) {
        guard !entries.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            entries.map(\.urlString).joined(separator: "\n"),
            forType: .string
        )
    }

    private func requestDeletion(_ identifiers: Set<BrowsingHistoryEntry.ID>) {
        guard !identifiers.isEmpty else { return }
        pendingDeletion = identifiers
        showsDeleteConfirmation = true
    }

    private func deletePendingEntries() {
        let urls = Set(history.records.lazy
            .filter { pendingDeletion.contains($0.id) }
            .map(\.url))
        history.remove(urls)
        selection.subtract(pendingDeletion)
        pendingDeletion.removeAll()
    }
}
