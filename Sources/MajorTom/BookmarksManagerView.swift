import AppKit
import MajorTomCore
import SwiftUI

/// The bookmark manager, laid out as Chrome's is: folders down the left, the selected
/// folder's contents on the right, a search field and a New Folder control across the top.
///
/// It is a native view rather than a generated page. The document pipeline runs with
/// `default-src 'none'` and page JavaScript disabled, so a manager rendered as HTML could
/// not offer inline renaming or drag-to-reorder at all. It still lives at a real address —
/// `about:bookmarks` — so Back, Forward, history and the address field behave normally.
@available(macOS 26.0, *)
struct BookmarksManagerView: View {
    @ObservedObject var bookmarks: BookmarksModel
    /// `inNewTab` is true for a Command-click or the context-menu item.
    let open: (URL, Bool) -> Void

    @State private var selectedFolderID: UUID?
    @State private var search = ""
    @State private var newFolderName = ""
    @State private var showsNewFolderPrompt = false
    @State private var renamingBookmarkID: UUID?
    @State private var renameText = ""

    private var selectedFolder: BookmarkFolder? {
        bookmarks.collection.folders.first { $0.id == selectedFolderID }
            ?? bookmarks.collection.folders.first
    }

    /// Searching looks across every folder, as Chrome's does — when you are hunting for a
    /// bookmark you rarely remember which folder you filed it in.
    private var visibleBookmarks: [Bookmark] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return selectedFolder?.bookmarks ?? [] }
        return bookmarks.collection.allBookmarks.filter { bookmark in
            bookmark.title.lowercased().contains(query)
                || bookmark.url.absoluteString.lowercased().contains(query)
        }
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                folderList
                    .frame(width: 220)
                Divider()
                bookmarkList
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            selectedFolderID = selectedFolderID ?? bookmarks.collection.favoritesID
            bookmarks.refreshFavicons()
        }
        .alert("New Folder", isPresented: $showsNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Add") {
                bookmarks.addFolder(named: newFolderName)
                newFolderName = ""
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Bookmarks", systemImage: "book")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 12)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Button("New Folder", systemImage: "folder.badge.plus") {
                showsNewFolderPrompt = true
            }
            .labelStyle(.iconOnly)
            .help("New Folder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var folderList: some View {
        List(selection: $selectedFolderID) {
            ForEach(bookmarks.collection.folders) { folder in
                HStack(spacing: 6) {
                    Image(systemName: folder.id == bookmarks.collection.favoritesID
                        ? "star"
                        : "folder")
                        .foregroundStyle(.secondary)
                    Text(folder.name)
                    Spacer(minLength: 0)
                    Text("\(folder.bookmarks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(folder.id)
                .contextMenu {
                    // Favourites is what the Favourites bar shows, so it always exists and
                    // cannot be renamed or deleted.
                    if folder.id != bookmarks.collection.favoritesID {
                        Button("Rename Folder…") { promptRenameFolder(folder) }
                        Button("Delete Folder", role: .destructive) {
                            bookmarks.removeFolder(with: folder.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var bookmarkList: some View {
        if visibleBookmarks.isEmpty {
            ContentUnavailableView {
                Label(isSearching ? "No Matches" : "No Bookmarks", systemImage: "bookmark")
            } description: {
                Text(isSearching
                    ? "No bookmark matches that search."
                    : "Add the page you are reading with Command-D.")
            }
        } else {
            List {
                ForEach(visibleBookmarks) { bookmark in
                    row(for: bookmark)
                }
                // Reordering is only meaningful within one folder, so it is offered when
                // a folder is being shown rather than a cross-folder search result.
                .onMove { offsets, destination in
                    guard !isSearching, let folder = selectedFolder else { return }
                    var identifiers = folder.bookmarks.map(\.id)
                    identifiers.move(fromOffsets: offsets, toOffset: destination)
                    bookmarks.reorder(folderWith: folder.id, to: identifiers)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(for bookmark: Bookmark) -> some View {
        HStack(spacing: 8) {
            if let favicon = bookmarks.favicon(for: bookmark.url) {
                Text(favicon)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.tertiary)
            }

            if renamingBookmarkID == bookmark.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        bookmarks.rename(bookmarkWith: bookmark.id, to: renameText)
                        renamingBookmarkID = nil
                    }
                    .onExitCommand { renamingBookmarkID = nil }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.title)
                        .lineLimit(1)
                    Text(bookmark.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(bookmark.url, false) }
        .contextMenu {
            Button("Open") { open(bookmark.url, false) }
            Button("Open in New Tab") { open(bookmark.url, true) }
            Divider()
            Button("Rename…") {
                renameText = bookmark.title
                renamingBookmarkID = bookmark.id
            }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            if bookmarks.collection.folders.count > 1 {
                Menu("Move to Folder") {
                    ForEach(bookmarks.collection.folders) { folder in
                        Button(folder.name) {
                            bookmarks.move(bookmarkWith: bookmark.id, toFolderWith: folder.id)
                        }
                        .disabled(folder.id == bookmarks.collection.folder(containing: bookmark.id)?.id)
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { bookmarks.remove(bookmarkWith: bookmark.id) }
        }
    }

    private func promptRenameFolder(_ folder: BookmarkFolder) {
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = folder.name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bookmarks.renameFolder(with: folder.id, to: field.stringValue)
    }
}

/// The sheet shown by Add Bookmark, offering a name and a destination folder.
@available(macOS 26.0, *)
struct AddBookmarkView: View {
    let url: URL
    let suggestedTitle: String
    @ObservedObject var bookmarks: BookmarksModel
    let dismiss: () -> Void

    @State private var title: String
    @State private var folderID: UUID
    @FocusState private var titleIsFocused: Bool

    init(
        url: URL,
        suggestedTitle: String,
        bookmarks: BookmarksModel,
        dismiss: @escaping () -> Void
    ) {
        self.url = url
        self.suggestedTitle = suggestedTitle
        self.bookmarks = bookmarks
        self.dismiss = dismiss
        _title = State(initialValue: suggestedTitle)
        _folderID = State(initialValue: bookmarks.collection.favoritesID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Bookmark")
                .font(.headline)
            Text(url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Form {
                TextField("Name", text: $title)
                    .focused($titleIsFocused)
                    .onSubmit(save)
                Picker("Folder", selection: $folderID) {
                    ForEach(bookmarks.collection.folders) { folder in
                        Text(folder.name).tag(folder.id)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { titleIsFocused = true }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bookmarks.add(title: trimmed, url: url, toFolderWith: folderID)
        dismiss()
    }
}
