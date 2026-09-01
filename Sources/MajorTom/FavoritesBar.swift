import AppKit
import MajorTomAppKitSupport
import MajorTomCore
import SwiftUI

/// A native SwiftUI Favorites Bar with whole-item overflow and pointer reordering.
@available(macOS 26.0, *)
struct FavoritesBar: View {
    @ObservedObject var bookmarks: BookmarksModel
    let open: (URL, Bool) -> Void
    let openInNewWindow: (URL) -> Void

    @State private var availableWidth: CGFloat = 0
    @State private var editor: FavoriteEditorRequest?
    @State private var hoveredBookmarkID: UUID?
    @State private var draggedBookmarkID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var dropInsertionIndex: Int?

    private var favorites: [Bookmark] { bookmarks.collection.favorites.bookmarks }
    private var itemWidths: [CGFloat] { favorites.map(itemWidth) }

    private var needsOverflow: Bool {
        FavoritesBarOverflowLayout.requiredWidth(itemWidths: itemWidths) > availableWidth
    }

    private var visibleCount: Int {
        guard availableWidth > 0 else { return favorites.count }
        let bookmarkWidth = max(availableWidth - (needsOverflow ? 28 : 0), 0)
        return FavoritesBarOverflowLayout.visibleItemCount(
            itemWidths: itemWidths,
            availableWidth: bookmarkWidth
        )
    }

    private var visibleFavorites: ArraySlice<Bookmark> { favorites.prefix(visibleCount) }
    private var hiddenFavorites: ArraySlice<Bookmark> { favorites.dropFirst(visibleCount) }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 4) {
                ForEach(Array(visibleFavorites)) { bookmark in
                    favoriteButton(bookmark)
                        .frame(width: itemWidth(for: bookmark), height: 24)
                        .contentShape(Rectangle())
                        .opacity(draggedBookmarkID == bookmark.id ? 0 : 1)
                        .overlay {
                            if draggedBookmarkID == bookmark.id {
                                dragPreview(for: bookmark)
                            }
                        }
                        .offset(
                            x: draggedBookmarkID == bookmark.id ? dragTranslation.width : 0,
                            y: draggedBookmarkID == bookmark.id ? dragTranslation.height : 0
                        )
                        .zIndex(draggedBookmarkID == bookmark.id ? 1 : 0)
                        .shadow(
                            color: .black.opacity(draggedBookmarkID == bookmark.id ? 0.2 : 0),
                            radius: 4,
                            y: 2
                        )
                        .popover(
                            isPresented: editorBinding(for: bookmark.id),
                            arrowEdge: .bottom
                        ) {
                            if let editor, editor.bookmarkID == bookmark.id {
                                FavoriteEditorPopover(request: editor) { value in
                                    commit(value, for: editor)
                                }
                            }
                        }
                }

                if needsOverflow {
                    overflowMenu
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, needsOverflow ? 2 : 10)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if let x = dropIndicatorX {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 22)
                        .offset(x: x)
                        .allowsHitTesting(false)
                }
            }
            .background {
                FavoritesDragGestureBridge(
                    items: visibleFavorites.map {
                        FavoriteDragItem(id: $0.id, width: itemWidth(for: $0))
                    },
                    changed: updateDrag,
                    ended: finishDrag
                )
            }
            .onAppear { availableWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
        .onAppear { bookmarks.refreshFavicons() }
    }

    private func favoriteButton(_ bookmark: Bookmark) -> some View {
        Button {
            open(bookmark.url, NSEvent.modifierFlags.contains(.command))
        } label: {
            Text(displayTitle(for: bookmark))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        // SwiftUI's native hoverEffect is unavailable on macOS. A semantic foreground
        // tint gives the same system-adaptive highlight in Aqua and Dark Aqua.
        .background {
            if hoveredBookmarkID == bookmark.id {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .onHover { hovering in
            hoveredBookmarkID = hovering ? bookmark.id : nil
        }
        .help(bookmark.url.absoluteString)
        .accessibilityLabel(bookmark.title)
        .accessibilityHint(bookmark.url.absoluteString)
        .contextMenu {
            Button("Open in New Tab", systemImage: BrowserMenuIcon.newTab) {
                open(bookmark.url, true)
            }
            Button("Open in New Window", systemImage: BrowserMenuIcon.newWindow) {
                openInNewWindow(bookmark.url)
            }
            Divider()
            Button("Copy Address", systemImage: BrowserMenuIcon.copyLink) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Rename", systemImage: "pencil") {
                editor = FavoriteEditorRequest(bookmark: bookmark, kind: .title)
            }
            Button("Edit Address", systemImage: "link") {
                editor = FavoriteEditorRequest(bookmark: bookmark, kind: .address)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                bookmarks.remove(bookmarkWith: bookmark.id)
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(Array(hiddenFavorites)) { bookmark in
                Button(displayTitle(for: bookmark)) { open(bookmark.url, false) }
                    .help(bookmark.url.absoluteString)
            }
        } label: {
            Image(systemName: "chevron.right.2")
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show More Favorites")
        .accessibilityLabel("Show More Favorites")
    }

    private func dragPreview(for bookmark: Bookmark) -> some View {
        Text(displayTitle(for: bookmark))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
    }

    private var dropIndicatorX: CGFloat? {
        guard let draggedBookmarkID, let dropInsertionIndex else { return nil }
        let visible = Array(visibleFavorites)
        let remaining = visible.filter { $0.id != draggedBookmarkID }
        guard !remaining.isEmpty else { return 10 }

        if dropInsertionIndex < remaining.count {
            let targetID = remaining[dropInsertionIndex].id
            var x: CGFloat = 10
            for bookmark in visible {
                if bookmark.id == targetID { return x - 2 }
                x += itemWidth(for: bookmark) + 4
            }
        }

        guard let last = remaining.last else { return 10 }
        var x: CGFloat = 10
        for bookmark in visible {
            if bookmark.id == last.id { return x + itemWidth(for: bookmark) + 2 }
            x += itemWidth(for: bookmark) + 4
        }
        return nil
    }

    private func displayTitle(for bookmark: Bookmark) -> String {
        bookmarks.favicon(for: bookmark.url)
            .map { "\($0)  \(bookmark.title)" } ?? bookmark.title
    }

    private func itemWidth(for bookmark: Bookmark) -> CGFloat {
        let width = ceil((displayTitle(for: bookmark) as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]).width) + 14
        return min(max(width, 44), 280)
    }

    private func editorBinding(for bookmarkID: UUID) -> Binding<Bool> {
        Binding {
            editor?.bookmarkID == bookmarkID
        } set: { presented in
            if !presented, editor?.bookmarkID == bookmarkID { editor = nil }
        }
    }

    private func commit(_ value: String, for request: FavoriteEditorRequest) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.kind {
        case .title:
            guard !trimmed.isEmpty else { return false }
            bookmarks.rename(bookmarkWith: request.bookmarkID, to: trimmed)
        case .address:
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme, !scheme.isEmpty else { return false }
            bookmarks.updateAddress(bookmarkWith: request.bookmarkID, to: url)
        }
        editor = nil
        return true
    }

    private func updateDrag(id: UUID, translation: CGSize, start: CGPoint) {
        if draggedBookmarkID == nil {
            draggedBookmarkID = id
        }
        guard draggedBookmarkID == id else { return }
        dragTranslation = translation
        dropInsertionIndex = insertionIndex(for: id, translation: translation)
    }

    private func finishDrag(id: UUID, translation: CGSize) {
        guard draggedBookmarkID == id else { return }
        reorder(id, translation: translation)
        draggedBookmarkID = nil
        dragTranslation = .zero
        dropInsertionIndex = nil
    }

    private func reorder(_ sourceID: UUID, translation: CGSize) {
        guard let insertionIndex = insertionIndex(for: sourceID, translation: translation) else {
            return
        }
        var reordered = favorites
        guard let sourceIndex = reordered.firstIndex(where: { $0.id == sourceID }) else { return }
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: min(insertionIndex, reordered.count))
        persistOrder(reordered)
    }

    private func insertionIndex(for sourceID: UUID, translation: CGSize) -> Int? {
        let visible = Array(visibleFavorites)
        guard let sourceIndex = visible.firstIndex(where: { $0.id == sourceID }) else { return nil }
        let insertionIndex = FavoritesBarOverflowLayout.insertionIndex(
            itemWidths: visible.map(itemWidth),
            sourceIndex: sourceIndex,
            translation: translation.width
        )
        return insertionIndex
    }

    private func persistOrder(_ reordered: [Bookmark]) {
        guard reordered != favorites else { return }
        bookmarks.reorder(
            folderWith: bookmarks.collection.favoritesID,
            to: reordered.map(\.id)
        )
    }
}

@available(macOS 26.0, *)
private struct FavoriteDragItem: Equatable {
    let id: UUID
    let width: CGFloat
}

/// WebKit's native platform view can own a mouse stream even when SwiftUI draws over it.
/// A pan recognizer on the common AppKit ancestor observes only drags that begin inside
/// this bar and passes the stable bookmark identifier back to SwiftUI.
@available(macOS 26.0, *)
private struct FavoritesDragGestureBridge: NSViewRepresentable {
    let items: [FavoriteDragItem]
    let changed: (UUID, CGSize, CGPoint) -> Void
    let ended: (UUID, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.movedToWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.installRecognizer(for: view)
        }
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.installRecognizer(for: view)
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var owner: FavoritesDragGestureBridge
        weak var anchorView: AnchorView?
        private weak var recognizerHost: NSView?
        private var recognizer: NSPanGestureRecognizer?
        private var sourceID: UUID?
        private var startLocation: CGPoint = .zero

        init(owner: FavoritesDragGestureBridge) { self.owner = owner }

        func installRecognizer(for anchorView: AnchorView) {
            guard let host = anchorView.window?.contentView else { return }
            guard recognizerHost !== host else { return }
            if let recognizer { recognizerHost?.removeGestureRecognizer(recognizer) }

            let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan))
            recognizer.buttonMask = 0x1
            recognizer.delegate = self
            host.addGestureRecognizer(recognizer)
            recognizerHost = host
            self.recognizer = recognizer
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let anchorView,
                  let recognizer = gestureRecognizer as? NSPanGestureRecognizer else {
                return false
            }
            let location = recognizer.location(in: anchorView)
            guard anchorView.bounds.contains(location),
                  let id = itemID(at: location.x) else { return false }
            sourceID = id
            startLocation = location
            return true
        }

        @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let anchorView, let sourceID else { return }
            let pointTranslation = recognizer.translation(in: anchorView)
            let translation = CGSize(
                width: pointTranslation.x,
                // AppKit's positive Y points upward; SwiftUI's visual offset points down.
                height: -pointTranslation.y
            )
            switch recognizer.state {
            case .began, .changed:
                owner.changed(sourceID, translation, startLocation)
            case .ended:
                owner.ended(sourceID, translation)
                self.sourceID = nil
            case .cancelled, .failed:
                owner.ended(sourceID, .zero)
                self.sourceID = nil
            default:
                break
            }
        }

        private func itemID(at x: CGFloat) -> UUID? {
            var cursor: CGFloat = 10
            for item in owner.items {
                if x >= cursor, x <= cursor + item.width { return item.id }
                cursor += item.width + 4
            }
            return nil
        }
    }

    @MainActor
    final class AnchorView: NSView {
        var movedToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            movedToWindow?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@available(macOS 26.0, *)
private struct FavoriteEditorRequest: Identifiable {
    enum Kind { case title, address }

    let id = UUID()
    let bookmarkID: UUID
    let kind: Kind
    let initialValue: String

    init(bookmark: Bookmark, kind: Kind) {
        bookmarkID = bookmark.id
        self.kind = kind
        initialValue = kind == .title ? bookmark.title : bookmark.url.absoluteString
    }
}

@available(macOS 26.0, *)
private struct FavoriteEditorPopover: View {
    let request: FavoriteEditorRequest
    let save: (String) -> Bool

    @State private var value: String
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    init(request: FavoriteEditorRequest, save: @escaping (String) -> Bool) {
        self.request = request
        self.save = save
        _value = State(initialValue: request.initialValue)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(
                request.kind == .title ? "Bookmark Name" : "Address",
                text: $value
            )
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { submit() }
            .overlay {
                if isInvalid {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.red, lineWidth: 1)
                }
            }

            Button("Done") { submit() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .frame(width: request.kind == .title ? 320 : 520)
        .onAppear {
            isFocused = true
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func submit() {
        isInvalid = !save(value)
    }
}
