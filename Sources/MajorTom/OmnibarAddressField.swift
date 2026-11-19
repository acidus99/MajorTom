import AppKit
import Combine
import MajorTomAppKitSupport
import MajorTomCore
import SwiftUI

/// A native editor and a nonactivating suggestion panel. The panel never takes
/// keyboard focus away from the field editor, including when a row is clicked.
struct OmnibarAddressField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let searchProvider: SearchProvider
    let customSearchEndpoint: String
    let submit: () -> Void
    let search: (String) -> Void
    let cancel: () -> Void
    let openInNewTab: (URL) -> Void
    let openInNewWindow: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> AddressTextField {
        let field = AddressTextField(string: text)
        field.placeholderString = "Search or enter capsule address"
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Address and search")
        field.toolTip = "Search or Enter Capsule Address (⌘L)"
        field.delegate = context.coordinator
        field.focusChanged = { [weak coordinator = context.coordinator] _ in
            // AppKit installs the shared field editor after becomeFirstResponder.
            Task { @MainActor in coordinator?.beganEditing() }
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: AddressTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text {
            coordinator.externalTextChanged(text)
        }
        coordinator.applyFocusRequest()
        Task { @MainActor in coordinator.repositionPanel() }
    }

    static func dismantleNSView(_ field: AddressTextField, coordinator: Coordinator) {
        coordinator.tearDown()
        field.delegate = nil
        field.focusChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarAddressField
        weak var field: AddressTextField?
        private var panel: NSPanel?
        private var panelContent: AddressSuggestionsView?
        private var rows: [OmnibarRow] = []
        private var selectedID: String?
        private var input = ""
        private var completion: String?
        private var completedDestination: OmnibarDestination?
        private var allowsCompletion = false
        private var isEditing = false
        private var isDismissed = false
        private var searchTask: Task<Void, Never>?
        private var generation = 0
        private var appliedFocusRequest = 0
        private var eventMonitor: Any?
        private var observations: Set<AnyCancellable> = []

        init(parent: OmnibarAddressField) {
            self.parent = parent
            super.init()
            ApplicationServices.omnibar.$revision.dropFirst().sink { [weak self] _ in
                guard let self, self.isEditing else { return }
                // Do not leave a deleted history entry actionable while rebuilding.
                self.rejectCompletion()
                self.allowsCompletion = false
                self.rows = []
                self.panel?.orderOut(nil)
                self.requestMatches()
            }.store(in: &observations)
            NotificationCenter.default.publisher(for: .majorTomSelectOmnibar)
                .sink { [weak self] notification in
                    guard let self, let field = self.field,
                          let window = notification.object as? NSWindow,
                          window === field.window,
                          let request = notification.userInfo?["request"] as? Int else { return }
                    self.appliedFocusRequest = request
                    self.focusAndSelectAll()
                }.store(in: &observations)
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
                .sink { [weak self] notification in
                    guard let self, let window = notification.object as? NSWindow,
                          window === self.field?.window else { return }
                    self.dismiss()
                }.store(in: &observations)
            NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResizeNotification))
                .sink { [weak self] _ in self?.repositionPanel() }
                .store(in: &observations)
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, self.isEditing else { return event }
                if event.type == .keyDown {
                    if event.window === self.field?.window, self.field?.currentEditor() != nil,
                       event.keyCode == 36, event.modifierFlags.contains(.command) {
                        self.activateSelected(inNewTab: true)
                        return nil
                    }
                } else if event.window !== self.panel {
                    if let field = self.field, event.window === field.window,
                       field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                        self.isDismissed = false
                        Task { @MainActor in self.requestMatches() }
                    } else {
                        self.dismiss()
                    }
                }
                return event
            }
        }

        func tearDown() {
            searchTask?.cancel()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            observations.removeAll()
            if let panel { panel.parent?.removeChildWindow(panel) }
            panel?.close()
            panel = nil
            panelContent = nil
        }

        func applyFocusRequest() {
            guard parent.focusRequest != appliedFocusRequest, field?.window != nil else { return }
            appliedFocusRequest = parent.focusRequest
            focusAndSelectAll()
        }

        private func focusAndSelectAll() {
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            isDismissed = false
            if isEditing { requestMatches(showRecent: true) }
        }

        func beganEditing() {
            guard field?.currentEditor() != nil else { return }
            if !isEditing {
                input = field?.stringValue ?? ""
                isEditing = true
                isDismissed = false
                allowsCompletion = false
                // On initial focus offer Favorites and recent destinations, even
                // though the current address is selected for replacement.
                requestMatches(showRecent: true)
            } else if isDismissed {
                isDismissed = false
                requestMatches(showRecent: true)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { beganEditing() }

        func controlTextDidEndEditing(_ notification: Notification) {
            isEditing = false
            dismiss()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = field?.currentEditor() as? NSTextView else { return }
            let value = editor.string
            // Deletion, mid-string edits, and IME composition must never resurrect
            // a completion the reader is trying to remove.
            let event = NSApplication.shared.currentEvent
            allowsCompletion = !editor.hasMarkedText()
                && editor.selectedRange() == NSRange(location: (value as NSString).length, length: 0)
                && event?.keyCode != 51 && event?.keyCode != 117
                && (value as NSString).length > (input as NSString).length
            input = value
            completion = nil
            completedDestination = nil
            selectedID = nil
            isDismissed = false
            parent.text = value
            if editor.hasMarkedText() {
                searchTask?.cancel()
                panel?.orderOut(nil)
                return
            }
            requestMatches()
        }

        func externalTextChanged(_ text: String) {
            searchTask?.cancel()
            generation += 1
            input = text
            completion = nil
            completedDestination = nil
            field?.stringValue = text
            panel?.orderOut(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                moveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                moveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                activateSelected()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if panel?.isVisible == true {
                    rejectCompletion()
                    dismiss()
                } else {
                    parent.cancel()
                    field?.window?.makeFirstResponder(nil)
                }
                return true
            default:
                return false
            }
        }

        private func requestMatches(showRecent: Bool = false) {
            searchTask?.cancel()
            generation += 1
            let requestedGeneration = generation
            let query = showRecent ? "" : input
            let sourceRevision = ApplicationServices.omnibar.revision
            let currentTabID = NativeTabCoordinator.shared.omnibarTabID(for: field?.window)
            searchTask = Task { [weak self] in
                guard let matches = await ApplicationServices.omnibar.search(query, excludingTabID: currentTabID), !Task.isCancelled,
                      let self, self.isEditing, !self.isDismissed,
                      self.generation == requestedGeneration,
                      ApplicationServices.omnibar.revision == sourceRevision,
                      let editor = self.field?.currentEditor() as? NSTextView,
                      !editor.hasMarkedText() else { return }
                if self.allowsCompletion && !showRecent && self.selectedID == nil,
                   let completion = matches.completion,
                   editor.selectedRange() == NSRange(location: (self.input as NSString).length, length: 0) {
                    self.completion = completion
                    self.completedDestination = matches.completedDestination
                    editor.string = completion
                    self.field?.stringValue = completion
                    editor.setSelectedRange(NSRange(
                        location: (self.input as NSString).length,
                        length: (completion as NSString).length - (self.input as NSString).length
                    ))
                    self.parent.text = completion
                }
                self.makeRows(matches: matches, showRecent: showRecent)
                self.showPanel()
            }
        }

        private func makeRows(matches: OmnibarMatches, showRecent: Bool) {
            var newRows: [OmnibarRow] = []
            let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
            var primaryURL: URL?
            if !showRecent && !query.isEmpty {
                if let destination = completedDestination, completion != nil {
                    primaryURL = destination.url
                    newRows.append(OmnibarRow(
                        id: "primary", title: "Top Hit — " + destination.title,
                        detail: sourceDescription(destination) + " · " + destination.url.absoluteString,
                        symbol: destination.tabID != nil ? "square.on.square" : destination.isBookmark ? "star" : "globe",
                        action: .destination(destination)
                    ))
                } else {
                    let endpoint = parent.searchProvider.endpoint(customEndpoint: parent.customSearchEndpoint)
                    if let result = try? AddressInputInterpreter(searchEndpoint: endpoint).interpret(query) {
                        switch result {
                        case .gemini(let target):
                            let searchURL = GeminiQueryEncoding.url(base: endpoint, query: query)
                            if target.url == searchURL { break }
                            primaryURL = target.url
                        case .external(let url): primaryURL = url
                        case .internalPage(let page): primaryURL = page.url
                        case .viewSource(let target): primaryURL = ViewSourceURL.wrap(target.url)
                        }
                    }
                    if let primaryURL {
                        newRows.append(OmnibarRow(id: "primary", title: "Go To " + query, detail: primaryURL.absoluteString, symbol: "arrow.right", action: .navigate(primaryURL)))
                    }
                }
                newRows.append(OmnibarRow(
                    id: primaryURL == nil ? "primary" : "search",
                    title: "Search with " + providerName, detail: query,
                    symbol: "magnifyingglass", action: .search(query)
                ))
            }
            for destination in matches.destinations where destination.url != primaryURL {
                newRows.append(OmnibarRow(
                    id: destination.id, title: destination.title,
                    detail: sourceDescription(destination) + " · " + destination.url.absoluteString,
                    symbol: destination.tabID != nil ? "square.on.square"
                        : destination.isBookmark ? "star" : "clock",
                    action: .destination(destination)
                ))
            }
            rows = Array(newRows.prefix(showRecent || query.isEmpty ? 6 : 8))
            if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }

        private var providerName: String {
            switch parent.searchProvider {
            case .kennedy: "Kennedy"
            case .tlgs: "TLGS"
            case .custom: "Custom Search"
            }
        }

        private func sourceDescription(_ destination: OmnibarDestination) -> String {
            var sources: [String] = []
            if destination.tabID != nil { sources.append("Switch to Tab") }
            if destination.isFavorite { sources.append("Favorite") }
            else if destination.isBookmark { sources.append("Bookmark") }
            if sources.isEmpty { sources.append("History") }
            return sources.joined(separator: " · ")
        }

        private func rejectCompletion() {
            if completion != nil {
                field?.stringValue = input
                if let editor = field?.currentEditor() as? NSTextView {
                    editor.string = input
                    editor.setSelectedRange(NSRange(location: (input as NSString).length, length: 0))
                }
                parent.text = input
                completion = nil
                completedDestination = nil
            }
        }

        private func moveSelection(_ offset: Int) {
            if panel?.isVisible != true {
                isDismissed = false
                allowsCompletion = false
                requestMatches(showRecent: input == parent.text && !input.isEmpty)
                return
            }
            guard !rows.isEmpty else { return }
            let current = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
            let next = current.map { min(rows.count - 1, max(0, $0 + offset)) }
                ?? (offset > 0 ? 0 : rows.count - 1)
            selectedID = rows[next].id
            renderPanel()
            if let panel {
                NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                    .announcement: rows[next].title + ", " + rows[next].detail,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ])
            }
        }

        private func activateSelected(inNewTab: Bool = false) {
            let row = selectedID.flatMap { id in rows.first(where: { $0.id == id }) }
            if let row { activate(row, inNewTab: inNewTab); return }
            let value = field?.stringValue ?? parent.text
            finishEditing()
            if inNewTab {
                let endpoint = parent.searchProvider.endpoint(customEndpoint: parent.customSearchEndpoint)
                if let result = try? AddressInputInterpreter(searchEndpoint: endpoint).interpret(value) {
                    switch result {
                    case .gemini(let target): parent.openInNewTab(target.url)
                    case .external(let url): parent.openInNewTab(url)
                    case .internalPage(let page): parent.openInNewTab(page.url)
                    case .viewSource(let target):
                        if let url = ViewSourceURL.wrap(target.url) { parent.openInNewTab(url) }
                    }
                }
            } else {
                parent.text = value
                parent.submit()
            }
        }

        private func activate(_ row: OmnibarRow, inNewTab: Bool = false, inNewWindow: Bool = false) {
            finishEditing()
            if let url = row.url {
                if inNewWindow { parent.openInNewWindow(url); return }
                if inNewTab { parent.openInNewTab(url); return }
            }
            switch row.action {
            case .search(let query):
                if inNewTab || inNewWindow {
                    let endpoint = parent.searchProvider.endpoint(customEndpoint: parent.customSearchEndpoint)
                    if let url = GeminiQueryEncoding.url(base: endpoint, query: query) {
                        if inNewWindow { parent.openInNewWindow(url) } else { parent.openInNewTab(url) }
                    }
                } else { parent.search(query) }
            case .navigate(let url):
                parent.text = url.absoluteString
                parent.submit()
            case .destination(let destination):
                if let id = destination.tabID, NativeTabCoordinator.shared.activateOmnibarTab(id) { return }
                parent.text = destination.url.absoluteString
                parent.submit()
            }
        }

        private func finishEditing() {
            dismiss()
            field?.window?.makeFirstResponder(nil)
            parent.cancel()
        }

        private func dismiss() {
            isDismissed = true
            generation += 1
            searchTask?.cancel()
            selectedID = nil
            rows = []
            panel?.orderOut(nil)
            field?.setAccessibilityLinkedUIElements(nil)
        }

        private func showPanel() {
            guard !rows.isEmpty, let window = field?.window, window.isKeyWindow else {
                panel?.orderOut(nil)
                return
            }
            if panel == nil {
                let panel = OmnibarPanel(
                    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false
                )
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = true
                panel.hidesOnDeactivate = true
                panel.setAccessibilityLabel("Address Suggestions")
                self.panel = panel
            }
            renderPanel()
            if let panel {
                if panel.parent !== window {
                    panel.parent?.removeChildWindow(panel)
                    window.addChildWindow(panel, ordered: .above)
                }
                repositionPanel()
                panel.orderFront(nil)
                if let panelContent { field?.setAccessibilityLinkedUIElements([panelContent]) }
            }
        }

        private func renderPanel() {
            if panelContent == nil {
                let content = AddressSuggestionsView(frame: NSRect(
                    x: 0, y: 0, width: field?.bounds.width ?? 340, height: CGFloat(rows.count) * 50 + 12
                ))
                panelContent = content
                panel?.contentView = content
            }
            panel?.appearance = field?.effectiveAppearance
            panelContent?.setItems(rows.map { row in
                let menu: NSMenu?
                if let url = row.url {
                    let actions = NSMenu()
                    actions.addItem(OmnibarMenuAction.item("Open Link in New Tab") { [weak self] in
                        self?.activate(row, inNewTab: true)
                    })
                    actions.addItem(OmnibarMenuAction.item("Open Link in New Window") { [weak self] in
                        self?.activate(row, inNewWindow: true)
                    })
                    actions.addItem(.separator())
                    actions.addItem(OmnibarMenuAction.item("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                    })
                    menu = actions
                } else { menu = nil }
                return AddressSuggestionItem(
                    title: row.title, detail: row.detail, symbol: row.symbol,
                    isSelected: selectedID == row.id, menu: menu,
                    activate: { [weak self] in self?.activate(row) }
                )
            })
        }

        func repositionPanel() {
            guard let panel, let field, let window = field.window else { return }
            let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? rect
            let width = min(max(rect.width, 340), screen.width)
            let height = CGFloat(rows.count) * 50 + 12
            let x = min(max(rect.minX, screen.minX), screen.maxX - width)
            let frame = NSRect(x: x, y: max(screen.minY, rect.minY - height - 4), width: width, height: height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
    }
}

private final class OmnibarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct OmnibarRow: Identifiable {
    enum Action {
        case navigate(URL)
        case search(String)
        case destination(OmnibarDestination)
    }
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let action: Action

    var url: URL? {
        switch action {
        case .navigate(let url): url
        case .destination(let destination): destination.url
        case .search: nil
        }
    }
}

@MainActor
private final class OmnibarMenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc private func performAction() { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = OmnibarMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(performAction), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
