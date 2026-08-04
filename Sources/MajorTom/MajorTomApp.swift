import AppKit
import Combine
import MajorTomCore
import SwiftUI

private struct BrowserWindowDestination: Codable, Hashable {
    let id: UUID
    let url: URL?

    init(url: URL? = nil) {
        id = UUID()
        self.url = url
    }
}

@main
struct MajorTomApp: App {
    @NSApplicationDelegateAdaptor(MajorTomApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(for: BrowserWindowDestination.self) { destination in
            NativeFoundationView(initialURL: destination.wrappedValue.url)
        } defaultValue: {
            BrowserWindowDestination()
        }
        .defaultSize(width: 1_100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .majorTomNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .majorTomCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Close Window") {
                    NotificationCenter.default.post(name: .majorTomCloseWindow, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button("Close All Windows") {
                    NotificationCenter.default.post(name: .majorTomCloseAllWindows, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .option])

                Divider()

                Button("Open Location…") {
                    NotificationCenter.default.post(name: .majorTomFocusLocation, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Save Page As…") {
                    NotificationCenter.default.post(name: .majorTomSavePage, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Print…") {
                    NotificationCenter.default.post(name: .majorTomPrint, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Reload Page") {
                    NotificationCenter.default.post(name: .majorTomReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Stop Loading") {
                    NotificationCenter.default.post(name: .majorTomStop, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("Show Page Source") {
                    NotificationCenter.default.post(name: .majorTomShowSource, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .option])

                Button("Find…") {
                    NotificationCenter.default.post(name: .majorTomFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .majorTomZoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .majorTomZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") {
                    NotificationCenter.default.post(name: .majorTomActualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("History") {
                Button("Back") { NotificationCenter.default.post(name: .majorTomBack, object: nil) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { NotificationCenter.default.post(name: .majorTomForward, object: nil) }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Home") { NotificationCenter.default.post(name: .majorTomHome, object: nil) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                // Command-Up/Down are the system's document scroll shortcuts, so binding
                // Up One Level there fought the text system and neither worked reliably.
                Button("Up One Level") { NotificationCenter.default.post(name: .majorTomUp, object: nil) }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button("Capsule Root") { NotificationCenter.default.post(name: .majorTomRoot, object: nil) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            }
        }

        Settings {
            BrowserSettingsView()
        }
    }
}

private final class MajorTomApplicationDelegate: NSObject, NSApplicationDelegate {
    private var commandKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        installCommandKeyMonitor()
        DispatchQueue.main.async {
            NSApplication.shared.activate()
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            self.removeDuplicateCloseCommand()
        }
    }

    /// Drops the standard File ▸ Close item that SwiftUI injects for a `WindowGroup`.
    ///
    /// It claims ⌘W, which this app gives to Close Tab, and two menu items sharing one
    /// key equivalent resolve unpredictably. "Close" is also the wrong verb for a tabbed
    /// browser: ⌘W closes the tab and ⇧⌘W closes the window. Matched on the action
    /// selector rather than the title, since titles are localised.
    ///
    /// Deferred to the next run loop turn because SwiftUI builds the main menu after
    /// applicationDidFinishLaunching returns.
    @MainActor
    private func removeDuplicateCloseCommand() {
        guard let fileMenu = NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu else {
            return
        }
        for item in fileMenu.items where item.action == #selector(NSWindow.performClose(_:)) {
            fileMenu.removeItem(item)
        }
    }

    /// Safari also navigates with Command-Left/Right. There is no way to express a
    /// second key equivalent for one SwiftUI command, so this is an application-wide
    /// monitor that posts the same notification the History menu posts. It lives on
    /// the delegate rather than on each tab view: a per-view monitor was installed
    /// once per open window, so every window reacted to one key press.
    private func installCommandKeyMonitor() {
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = event.keyCode
            if modifiers == .command, event.charactersIgnoringModifiers == "=" {
                // Accept Command-= in addition to the standard Command-+ menu shortcut.
                NotificationCenter.default.post(name: .majorTomZoomIn, object: nil)
                return nil
            }
            guard modifiers == .command, keyCode == 123 || keyCode == 124 else { return event }

            // Command-Left/Right are "move to beginning/end of line" while editing.
            // Swallowing them there broke standard Mac text editing in the address
            // and find fields (spec 11.4). Local key monitors run on the main thread.
            // Only a genuinely editable responder should keep these keys. The previous
            // class-only test was both too broad and too narrow: a diagnostic showed the
            // web content responder is `WebKit.WebPageWebView` (so the test already
            // failed there, and this event is correctly swallowed), while any
            // non-editable text-system view would have wrongly kept it.
            let isEditingText = MainActor.assumeIsolated { () -> Bool in
                guard let responder = NSApplication.shared.keyWindow?.firstResponder else {
                    return false
                }
                if let textView = responder as? NSTextView { return textView.isEditable }
                if let field = responder as? NSTextField { return field.isEditable }
                return false
            }
            guard !isEditingText else { return event }

            NotificationCenter.default.post(
                name: keyCode == 123 ? .majorTomBack : .majorTomForward,
                object: nil
            )
            return nil
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            DispatchQueue.main.async { [weak self] in
                self?.openFreshBrowserWindow()
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    private func openFreshBrowserWindow() {
        guard let fileMenu = NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu,
              let newWindow = fileMenu.items.first(where: { $0.title == "New Window" }),
              let action = newWindow.action else { return }
        NSApplication.shared.sendAction(action, to: newWindow.target, from: newWindow)
    }
}

private struct NativeFoundationView: View {
    @ObservedObject private var settings = BrowserSettingsStore.shared
    let initialURL: URL?

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                BrowserWindowView(initialURL: initialURL)
            } else {
                ContentUnavailableView {
                    Label("Major Tom requires macOS 26", systemImage: "sparkles")
                } description: {
                    Text("The current native streaming renderer uses WebKit APIs introduced in macOS 26.")
                }
                .frame(minWidth: 720, minHeight: 480)
            }
        }
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch settings.preferences.applicationAppearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@available(macOS 26.0, *)
private struct BrowserWindowView: View {
    @StateObject private var session: BrowserWindowSession
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    /// Close All Windows has to reach every browser window, not only the key one, so
    /// each window needs a handle on the NSWindow it is hosted in.
    @State private var hostWindow: NSWindow?

    init(initialURL: URL? = nil) {
        _session = StateObject(wrappedValue: BrowserWindowSession(initialURL: initialURL))
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let selectedTab = session.selectedTab {
                BrowserTabView(browser: selectedTab.browser, chromeTopInset: 42)
                    .id(selectedTab.id)
            }
            BrowserTabStrip(session: session)
        }
        .navigationTitle(session.selectedTab?.browser.title ?? "Major Tom")
        .background(WindowAccessor(window: $hostWindow))
        .onAppear {
            session.openWindow = { url in
                openWindow(value: BrowserWindowDestination(url: url))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomNewTab)) { _ in
            guard controlActiveState == .key else { return }
            session.newTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomCloseTab)) { _ in
            guard controlActiveState == .key else { return }
            if session.closeSelectedTab() {
                NSApplication.shared.keyWindow?.performClose(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomCloseWindow)) { _ in
            guard hostWindow?.isKeyWindow == true else { return }
            closeHostWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomCloseAllWindows)) { _ in
            // Deliberately not key-scoped: every browser window answers. Panels such as
            // Settings and About are not browser windows, so they stay open, which is
            // what Safari does.
            closeHostWindow()
        }
    }

    /// Stops each tab's network work before the window goes away.
    ///
    /// Closing the window tears down the SwiftUI scene without visiting the tabs, so
    /// without this an in-flight request would keep streaming into a document nobody
    /// can see. `closeSelectedTab()` already does this for one tab.
    private func closeHostWindow() {
        for tab in session.tabs { tab.browser.stop() }
        hostWindow?.performClose(nil)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class BrowserWindowSession: ObservableObject {
    @MainActor
    final class Tab: Identifiable {
        let id = UUID()
        let browser: BrowserModel

        init(restoredState: RestoredTabState? = nil, initialURL: URL? = nil) {
            browser = BrowserModel(restoredState: restoredState, initialURL: initialURL)
        }
    }

    @Published private(set) var tabs: [Tab]
    @Published var selectedID: UUID? {
        didSet { scheduleSave() }
    }
    private var observers: [UUID: AnyCancellable] = [:]
    var openWindow: ((URL) -> Void)?

    init(initialURL: URL? = nil) {
        if let initialURL {
            tabs = [Tab(initialURL: initialURL)]
            selectedID = tabs.first?.id
        } else if !BrowserSessionRestorationState.hasRestoredInitialWindow,
           let restored = SessionRestorationStore.shared.load(), !restored.tabs.isEmpty {
            BrowserSessionRestorationState.hasRestoredInitialWindow = true
            tabs = restored.tabs.map { Tab(restoredState: $0) }
            selectedID = tabs.indices.contains(restored.selectedIndex)
                ? tabs[restored.selectedIndex].id
                : tabs.first?.id
        } else {
            BrowserSessionRestorationState.hasRestoredInitialWindow = true
            tabs = [Tab()]
            selectedID = tabs.first?.id
        }
        for tab in tabs { observe(tab) }
    }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedID } ?? tabs.first
    }

    func newTab(url: URL? = nil, select: Bool = true) {
        let tab = Tab(initialURL: url)
        tabs.append(tab)
        observe(tab)
        if select { selectedID = tab.id }
        // Only the selected tab has a view, and start() is normally driven by that
        // view's .task. A background tab therefore has to be started here, or a
        // Command-clicked link would sit blank until the tab was selected.
        tab.browser.start()
        scheduleSave()
    }

    @discardableResult
    func closeSelectedTab() -> Bool {
        guard let selectedID,
              let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return false }
        tabs[index].browser.stop()
        tabs.remove(at: index)
        observers.removeValue(forKey: selectedID)
        guard !tabs.isEmpty else { return true }
        self.selectedID = tabs[min(index, tabs.count - 1)].id
        scheduleSave()
        return false
    }

    private func observe(_ tab: Tab) {
        tab.browser.openInNewTab = { [weak self] url, background in
            self?.newTab(url: url, select: !background)
        }
        tab.browser.openInNewWindow = { [weak self] url in
            self?.openWindow?(url)
        }
        observers[tab.id] = tab.browser.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleSave() }
        }
    }

    private func scheduleSave() {
        let selectedIndex = tabs.firstIndex { $0.id == selectedID } ?? 0
        SessionRestorationStore.shared.save(RestoredWindowState(
            tabs: tabs.map { $0.browser.restorationState },
            selectedIndex: selectedIndex
        ))
    }
}

@available(macOS 26.0, *)
@MainActor
private enum BrowserSessionRestorationState {
    static var hasRestoredInitialWindow = false
}

@available(macOS 26.0, *)
private struct BrowserTabStrip: View {
    @ObservedObject var session: BrowserWindowSession

    /// The width below which a tab stops shrinking and the strip scrolls instead.
    /// Safari shares the available width among tabs until they would stop being
    /// readable, and only then scrolls; it never scrolls while slack remains.
    private static let minimumTabWidth: CGFloat = 150
    private static let tabSpacing: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.tabSpacing) {
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView(.horizontal) {
                        HStack(spacing: Self.tabSpacing) {
                            ForEach(session.tabs) { tab in
                                BrowserTabButton(
                                    browser: tab.browser,
                                    isSelected: session.selectedID == tab.id,
                                    select: { session.selectedID = tab.id },
                                    close: {
                                        session.selectedID = tab.id
                                        if session.closeSelectedTab() {
                                            NSApplication.shared.keyWindow?.performClose(nil)
                                        }
                                    }
                                )
                                .id(tab.id)
                            }
                        }
                        // Taking at least the available width keeps a handful of tabs
                        // stretched exactly as before; past that the tabs' own minimum
                        // wins and the overflow scrolls. Matching the reader's height
                        // keeps them centred in the strip.
                        .frame(
                            width: max(proxy.size.width, unshrunkWidth),
                            height: proxy.size.height,
                            alignment: .leading
                        )
                    }
                    .scrollIndicators(.never)
                    // Without this a tab past the fold is unreachable and invisible —
                    // including the background tab a Command-clicked link just created.
                    .onChange(of: session.selectedID) { _, id in
                        scrollIntoView(id, using: scroller)
                    }
                    .onChange(of: session.tabs.count) { _, _ in
                        scrollIntoView(session.selectedID, using: scroller)
                    }
                }
            }
            Button("New Tab", systemImage: "plus") { session.newTab() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .help("New Tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(.ultraThinMaterial)
    }

    /// Width the tabs occupy when none of them is compressed.
    private var unshrunkWidth: CGFloat {
        let count = CGFloat(session.tabs.count)
        guard count > 0 else { return 0 }
        return count * Self.minimumTabWidth + (count - 1) * Self.tabSpacing
    }

    private func scrollIntoView(_ id: UUID?, using scroller: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.18)) { scroller.scrollTo(id) }
    }
}

@available(macOS 26.0, *)
private struct BrowserTabButton: View {
    @ObservedObject var browser: BrowserModel
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Safari puts the close control hard against the leading edge of the tab.
            // The slot is always present, hidden rather than removed, so the title does
            // not shift when the pointer enters the tab and so VoiceOver can still
            // reach it without a mouse.
            Button("Close Tab", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .opacity(isHovered || isSelected ? 1 : 0)
                .accessibilityLabel("Close \(browser.title)")
                .accessibilityHidden(false)

            if browser.isLoading { ProgressView().controlSize(.mini) }
            Text(browser.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .frame(minWidth: 150, maxWidth: 240, minHeight: 30)
        .background(tabBackground, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(isSelected ? 0.82 : 0.56), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tabBackground: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        }
        return AnyShapeStyle(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
    }
}

@available(macOS 26.0, *)
private struct BrowserTabView: View {
    @ObservedObject var browser: BrowserModel
    let chromeTopInset: CGFloat
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var locationIsFocused: Bool
    @State private var showsFind = false
    @State private var contextMenuMonitor: Any?

    /// Menu commands are broadcast application-wide, so every window's selected tab
    /// receives them. Only the key window's tab may act, or one Command-R reloads
    /// every open window and one Command-S opens a save panel per window.
    private var isKeyWindow: Bool { controlActiveState == .key }

    var body: some View {
        ZStack(alignment: .top) {
            StreamingWebViewPrototype(browser: browser, findNavigatorIsPresented: $showsFind)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let file = urls.first(where: \.isFileURL) else { return false }
                    browser.openFile(file)
                    return true
                }
                // Safari puts the hovered link's destination bottom-left and leaves the
                // right for page status (spec 18.4, 21).
                .overlay(alignment: .bottomLeading) {
                    if let hovered = browser.hoveredLinkURL {
                        Text(hovered)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                            .padding(8)
                            .frame(maxWidth: 620, alignment: .leading)
                            .transition(.opacity)
                            .accessibilityLabel("Link destination: \(hovered)")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 7) {
                        if browser.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(browser.statusText)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .padding(8)
                }

            VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Safari joins Back and Forward into a single segmented control rather
                // than two separate bordered buttons. `.navigation` is the AppKit
                // control-group style that produces exactly that appearance.
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") {
                        browser.goBack()
                    }
                    .disabled(!browser.canGoBack)
                    .help("Back")

                    Button("Forward", systemImage: "chevron.right") {
                        browser.goForward()
                    }
                    .disabled(!browser.canGoForward)
                    .help("Forward")
                }
                .controlGroupStyle(.navigation)
                .labelStyle(.iconOnly)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .fixedSize()

                Button("Home", systemImage: "house") { browser.goHome() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42)
                    .help("Home")

                TextField("Search or enter capsule address", text: $browser.locationText)
                    .textFieldStyle(.roundedBorder)
                    .focused($locationIsFocused)
                    .onSubmit {
                        browser.submitLocation()
                        locationIsFocused = false
                    }
                    .onExitCommand {
                        browser.locationText = browser.committedURL?.absoluteString ?? browser.locationText
                        browser.validationMessage = nil
                        locationIsFocused = false
                    }
                    .accessibilityLabel("Address and search")

                if browser.isLoading {
                    Button("Stop", systemImage: "xmark") {
                        browser.stop()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42)
                    .help("Stop Loading")
                } else {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        browser.reload()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42)
                    .disabled(!browser.canReload)
                    .help("Reload Page")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
                if let validationMessage = browser.validationMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(validationMessage)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 7)
                    .accessibilityElement(children: .combine)
                }

                Divider()
            }
            .background(.ultraThinMaterial)
            .padding(.top, chromeTopInset)
        }
        .task { browser.start() }
        .onAppear { installContextMenuMonitor() }
        .onDisappear { removeContextMenuMonitor() }
        .onCommand(.majorTomFocusLocation, when: isKeyWindow) { locationIsFocused = true }
        .onCommand(.majorTomReload, when: isKeyWindow) { browser.reload() }
        .onCommand(.majorTomStop, when: isKeyWindow) { browser.stop() }
        .onCommand(.majorTomShowSource, when: isKeyWindow) { browser.showPageSource() }
        .onCommand(.majorTomSavePage, when: isKeyWindow) { Task { await browser.savePage() } }
        .onCommand(.majorTomPrint, when: isKeyWindow) { browser.printPage() }
        .onCommand(.majorTomFind, when: isKeyWindow) { showsFind = true }
        .onCommand(.majorTomZoomIn, when: isKeyWindow) { browser.zoomIn() }
        .onCommand(.majorTomZoomOut, when: isKeyWindow) { browser.zoomOut() }
        .onCommand(.majorTomActualSize, when: isKeyWindow) { browser.actualSize() }
        .onCommand(.majorTomBack, when: isKeyWindow) { browser.goBack() }
        .onCommand(.majorTomForward, when: isKeyWindow) { browser.goForward() }
        .onCommand(.majorTomHome, when: isKeyWindow) { browser.goHome() }
        .onCommand(.majorTomUp, when: isKeyWindow) { browser.goUpOneLevel() }
        .onCommand(.majorTomRoot, when: isKeyWindow) { browser.goToCapsuleRoot() }
        // Deliberately not window-scoped: a content-theme change must repaint every
        // open document, not just the one in front (spec 6.3).
        .onCommand(.majorTomContentThemeChanged, when: true) { browser.refreshContentTheme() }
        .sheet(item: $browser.trustPrompt) { prompt in
            TrustPromptView(prompt: prompt) { approved in
                browser.respondToTrust(allow: approved)
            }
        }
        .sheet(item: $browser.inputPrompt) { prompt in
            CapsuleInputView(prompt: prompt, validationMessage: browser.inputValidationMessage) { outcome in
                switch outcome {
                case .submit(let value):
                    browser.submitInput(value)
                case .cancel(let draft):
                    browser.cancelInput(draft: draft)
                }
            }
        }
    }

    private func installContextMenuMonitor() {
        removeContextMenuMonitor()
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isControlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
            guard event.type == .rightMouseDown || isControlClick,
                  let view = event.window?.contentView else { return event }
            let location = view.convert(event.locationInWindow, from: nil)
            browser.prepareContextMenu(at: location, in: view)
            return event
        }
    }

    private func removeContextMenuMonitor() {
        if let contextMenuMonitor {
            NSEvent.removeMonitor(contextMenuMonitor)
            self.contextMenuMonitor = nil
        }
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view.
///
/// SwiftUI gives a scene no handle on its own window, but Close Window and Close All
/// Windows both need one: the first must act only when its window is key, and the
/// second must act on every browser window at once.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // A view has no window until it has joined the hierarchy, which has not
        // happened yet at make time.
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Reassigning an unchanged value would republish state on every layout pass.
        guard window !== nsView.window else { return }
        DispatchQueue.main.async { window = nsView.window }
    }
}

@available(macOS 26.0, *)
final class ContextMenuTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }

    @objc func performAction() { action() }
}

@available(macOS 26.0, *)
private struct TrustPromptView: View {
    let prompt: BrowserModel.TrustPrompt
    let completion: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(prompt.title, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.title2.weight(.semibold))
            Text(prompt.explanation)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Capsule").foregroundStyle(.secondary)
                    Text("\(prompt.identity.endpoint.host):\(prompt.identity.endpoint.port)")
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Presented key").foregroundStyle(.secondary)
                    Text(prompt.identity.publicKeySHA256)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let previous = prompt.previousFingerprint {
                    GridRow {
                        Text("Previous key").foregroundStyle(.secondary)
                        Text(previous)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { completion(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Continue") { completion(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 610)
        .interactiveDismissDisabled()
    }
}

@available(macOS 26.0, *)
private enum CapsuleInputOutcome {
    case submit(String)
    /// Carries what was typed, so the same prompt can offer it back later.
    case cancel(draft: String)
}

@available(macOS 26.0, *)
private struct CapsuleInputView: View {
    let prompt: BrowserModel.InputPrompt
    let validationMessage: String?
    let completion: (CapsuleInputOutcome) -> Void
    @State private var value: String
    @FocusState private var isFocused: Bool
    private let budget: GeminiInputBudget

    init(
        prompt: BrowserModel.InputPrompt,
        validationMessage: String?,
        completion: @escaping (CapsuleInputOutcome) -> Void
    ) {
        self.prompt = prompt
        self.validationMessage = validationMessage
        self.completion = completion
        _value = State(initialValue: prompt.initialText)
        budget = GeminiInputBudget(promptURL: prompt.target.url)
    }

    private var remaining: Int { budget.remainingByteCount(for: value) }
    private var isWithinBudget: Bool { remaining >= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                // Which capsule is asking. A prompt is a request for information, and
                // the answer is about to be sent somewhere, so the destination belongs
                // on screen next to the question.
                Text(capsuleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(prompt.message)
                    .font(.headline)
            }
            Group {
                if prompt.isSensitive {
                    SecureField("Response", text: $value)
                } else {
                    TextField("Response", text: $value, axis: .vertical)
                        .lineLimit(1...6)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { submit() }

            HStack(alignment: .firstTextBaseline) {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Input error: \(validationMessage)")
                }
                Spacer(minLength: 8)
                Text(budgetLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isWithinBudget ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .accessibilityLabel(budgetAccessibilityLabel)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { completion(.cancel(draft: value)) }
                    .keyboardShortcut(.cancelAction)
                Button("Submit") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isWithinBudget)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { isFocused = true }
        .interactiveDismissDisabled()
    }

    private var capsuleLabel: String {
        let endpoint = prompt.target.endpoint
        return endpoint.port == GeminiRequestTarget.defaultPort
            ? endpoint.host
            : "\(endpoint.host):\(endpoint.port)"
    }

    /// Counts encoded bytes rather than characters: one typed character can cost up to
    /// twelve bytes once percent-encoded, so a character count would promise room that
    /// the request does not have.
    private var budgetLabel: String {
        isWithinBudget ? "\(remaining) bytes left" : "\(-remaining) bytes over"
    }

    private var budgetAccessibilityLabel: String {
        isWithinBudget
            ? "\(remaining) of \(budget.maximumEncodedByteCount) bytes remaining"
            : "Too long by \(-remaining) bytes"
    }

    private func submit() {
        guard isWithinBudget else { return }
        completion(.submit(value))
    }
}

private extension View {
    /// Application-wide command notifications are received by every window's selected
    /// tab. `condition` restricts the action to the window that should own it.
    func onCommand(
        _ name: Notification.Name,
        when condition: Bool,
        perform action: @escaping () -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in
            guard condition else { return }
            action()
        }
    }
}

private extension Notification.Name {
    static let majorTomNewTab = Notification.Name("MajorTomNewTab")
    static let majorTomCloseTab = Notification.Name("MajorTomCloseTab")
    static let majorTomCloseWindow = Notification.Name("MajorTomCloseWindow")
    static let majorTomCloseAllWindows = Notification.Name("MajorTomCloseAllWindows")
    static let majorTomFocusLocation = Notification.Name("MajorTomFocusLocation")
    static let majorTomReload = Notification.Name("MajorTomReload")
    static let majorTomStop = Notification.Name("MajorTomStop")
    static let majorTomShowSource = Notification.Name("MajorTomShowSource")
    static let majorTomSavePage = Notification.Name("MajorTomSavePage")
    static let majorTomPrint = Notification.Name("MajorTomPrint")
    static let majorTomFind = Notification.Name("MajorTomFind")
    static let majorTomZoomIn = Notification.Name("MajorTomZoomIn")
    static let majorTomZoomOut = Notification.Name("MajorTomZoomOut")
    static let majorTomActualSize = Notification.Name("MajorTomActualSize")
    static let majorTomBack = Notification.Name("MajorTomBack")
    static let majorTomForward = Notification.Name("MajorTomForward")
    static let majorTomHome = Notification.Name("MajorTomHome")
    static let majorTomUp = Notification.Name("MajorTomUp")
    static let majorTomRoot = Notification.Name("MajorTomRoot")
}
