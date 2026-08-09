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
    /// Observed so the Bookmarks menu lists the current favourites and reflects the
    /// Favourites-bar toggle.
    @ObservedObject private var bookmarks = BookmarksModel.shared
    @ObservedObject private var settings = BrowserSettingsStore.shared

    var body: some Scene {
        WindowGroup(for: BrowserWindowDestination.self) { destination in
            NativeFoundationView(
                initialURL: destination.wrappedValue.url,
                destinationID: destination.wrappedValue.id
            )
        } defaultValue: {
            BrowserWindowDestination()
        }
        .defaultSize(width: 1_100, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Major Tom") {
                    NotificationCenter.default.post(name: .majorTomAbout, object: nil)
                }
            }

            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .majorTomNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                // Close Tab is not declared here. It is the standard File ▸ Close item
                // that SwiftUI injects, retitled and retargeted at launch by
                // FileMenuCustomization, so ⌘W belongs to exactly one menu item.
                Button("Close Window") {
                    NotificationCenter.default.post(name: .majorTomCloseWindow, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button("Close All Windows") {
                    NotificationCenter.default.post(name: .majorTomCloseAllWindows, object: nil)
                }
                // Safari's shortcut. ⌥⌘W is deliberately left alone: that is Close Other
                // Tabs in Safari, so borrowing it here would misteach the gesture.
                .keyboardShortcut("w", modifiers: [.command, .option, .shift])

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

                Button("Check for Previous Versions") {
                    NotificationCenter.default.post(name: .majorTomArchive, object: nil)
                }

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

            CommandMenu("Bookmarks") {
                Button("Add Bookmark…") {
                    NotificationCenter.default.post(name: .majorTomAddBookmark, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Show Bookmarks") {
                    NotificationCenter.default.post(name: .majorTomShowBookmarks, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Toggle("Show Favorites Bar", isOn: settings.binding(\.showsFavoritesBar))
                    .keyboardShortcut("b", modifiers: [.command, .shift])

                Divider()

                // The Favourites folder inline, as Safari lists it, so a saved capsule is
                // one menu away rather than behind the manager.
                ForEach(bookmarks.collection.favorites.bookmarks) { bookmark in
                    Button(bookmark.title) {
                        NotificationCenter.default.post(
                            name: .majorTomOpenBookmark,
                            object: bookmark.url
                        )
                    }
                }
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
    private var aboutObserver: (any NSObjectProtocol)?
    private var menuObserver: (any NSObjectProtocol)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Native tab dragging is an AppKit window-tabbing feature. Opt in before the
        // first SwiftUI WindowGroup window is created so a tab dragged from any Major
        // Tom window can join another compatible Major Tom window.
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        installCommandKeyMonitor()
        // Observed here rather than in a window's view so About is handled consistently
        // while the application is running.
        aboutObserver = NotificationCenter.default.addObserver(
            forName: .majorTomAbout,
            object: nil,
            queue: .main
        ) { _ in
            // Delivered on the main queue, so main-actor isolation is guaranteed here.
            MainActor.assumeIsolated { AboutWindowPresenter.show() }
        }
        DispatchQueue.main.async {
            NSApplication.shared.activate()
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            FileMenuCustomization.apply()
            NativeTabMenuCustomization.install()
        }

        // SwiftUI rebuilds the main menu as scenes come and go, which would restore the
        // stock Close item, so the customisation is re-applied whenever a window takes
        // focus. Capture-free on purpose: sending the delegate into this closure is a data
        // race the compiler rightly refuses.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                FileMenuCustomization.apply()
                NativeTabMenuCustomization.apply()
            }
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
            let hasCommandOnly = modifiers.contains(.command)
                && modifiers.isDisjoint(with: [.shift, .option, .control])
            if hasCommandOnly, event.charactersIgnoringModifiers == "=" {
                // Accept Command-= in addition to the standard Command-+ menu shortcut.
                NotificationCenter.default.post(name: .majorTomZoomIn, object: nil)
                return nil
            }
            guard hasCommandOnly, keyCode == 123 || keyCode == 124 else { return event }

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
        // When no browser window is visible, let SwiftUI's WindowGroup handle the
        // reopen event and create its single default scene. Calling New Window here as
        // well races that scene restoration and produces two windows from one Dock click.
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Major Tom has no useful background-only mode. Once the final native window
        // (browser or panel) closes, terminate so a stale process cannot keep an old
        // bundle loaded and confuse subsequent launches.
        true
    }

    /// AppKit sends this responder-chain action when the native tab bar's plus button
    /// is clicked. SwiftUI's WindowGroup previously answered it by presenting a new
    /// standalone scene, which is also the path that caused the visible window flash.
    /// Route the native control through the same hidden-window attachment used by
    /// Command-T and link activation instead.
    @IBAction func newWindowForTab(_ sender: Any?) {
        guard #available(macOS 26.0, *),
              let parent = NSApplication.shared.keyWindow else { return }
        NativeTabCoordinator.shared.openTab(url: nil, from: parent, inBackground: false)
    }

}

@available(macOS 26.0, *)
@MainActor
private final class NativeTabCoordinator {
    static let shared = NativeTabCoordinator()
    static let tabbingIdentifier = "com.acidus.majortom.browser"

    /// Windows created outside SwiftUI's WindowGroup need a retained controller.
    /// Keeping the controller (rather than only the window) also gives AppKit the
    /// normal ownership relationship it expects for a manually-created window.
    private var windowControllers: [ObjectIdentifier: NSWindowController] = [:]
    private var closeObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]
    private var tabDragMonitor: Any?
    private var temporarilyShownTabBars: [NSWindow] = []
    private var tabDragCleanupTask: Task<Void, Never>?

    private init() {
        tabDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handleTabDragEvent(event)
            return event
        }
    }

    func configure(window: NSWindow) {
        // AppKit uses a matching, non-empty identifier to decide whether windows can
        // accept one another's tabs during a native tab drag.
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
    }

    /// Makes a one-tab window a native drop destination while another native tab is
    /// being dragged. AppKit only accepts a tab drop on a visible tab strip, so the
    /// otherwise-hidden singleton strips are exposed for the duration of the drag.
    private func handleTabDragEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            tabDragCleanupTask?.cancel()
            tabDragCleanupTask = nil
            if !temporarilyShownTabBars.isEmpty { finishTabDrag() }
            guard let source = tabbedBrowserWindow(at: NSEvent.mouseLocation),
                  isInNativeTabStrip(NSEvent.mouseLocation, of: source) else { return }

            // AppKit enters a private tracking loop as soon as its native tab starts
            // dragging, so leftMouseDragged may never reach an application event
            // monitor. Prepare destination strips on mouse-down, before that loop owns
            // the gesture.
            exposeSingletonTabBars(except: source)
            waitForTabDragToFinish()

        case .leftMouseUp:
            if !temporarilyShownTabBars.isEmpty {
                scheduleTabBarCleanup()
            }

        default:
            break
        }
    }

    private func tabbedBrowserWindow(at screenPoint: NSPoint) -> NSWindow? {
        NSApplication.shared.windows.first { window in
            window.isVisible
                && !window.isMiniaturized
                && window.tabbingIdentifier == Self.tabbingIdentifier
                && (window.tabGroup?.windows.count ?? 1) >= 2
                && window.tabGroup?.isTabBarVisible == true
                && window.frame.contains(screenPoint)
        }
    }

    private func isInNativeTabStrip(_ screenPoint: NSPoint, of window: NSWindow) -> Bool {
        guard window.tabbingIdentifier == Self.tabbingIdentifier,
              window.tabGroup?.isTabBarVisible == true else { return false }

        // Work in screen coordinates because AppKit's private tab controls may report
        // their event through a different internal view/window. The tab strip is the
        // lower row of the native chrome, immediately above unobscured content; the
        // ordinary draggable title bar is the upper row.
        let contentTop = window.convertPoint(toScreen: NSPoint(
            x: window.contentLayoutRect.minX,
            y: window.contentLayoutRect.maxY
        )).y
        let chromeHeight = window.frame.maxY - contentTop
        let tabStripHeight = min(40, max(24, chromeHeight * 0.58))
        let isInTabRow = screenPoint.y >= contentTop
            && screenPoint.y <= contentTop + tabStripHeight
        // The native plus button occupies the trailing end of the row and starts a new
        // tab rather than a tab drag, so it must not expose other windows as targets.
        let isBeforePlusButton = screenPoint.x < window.frame.maxX - 44
        return isInTabRow && isBeforePlusButton
    }

    private func exposeSingletonTabBars(except source: NSWindow) {
        for window in NSApplication.shared.windows where
            window !== source
                && window.isVisible
                && !window.isMiniaturized
                && window.tabbingIdentifier == Self.tabbingIdentifier
        {
            let tabCount = window.tabGroup?.windows.count ?? 1
            guard tabCount == 1, window.tabGroup?.isTabBarVisible != true else { continue }
            withoutTabBarAnimation { window.toggleTabBar(nil) }
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            temporarilyShownTabBars.append(window)
        }
    }

    private func waitForTabDragToFinish() {
        tabDragCleanupTask?.cancel()
        tabDragCleanupTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            // Let AppKit finish moving the NSWindow between tab groups before deciding
            // which singleton strips need to disappear again.
            try? await Task.sleep(for: .milliseconds(100))
            self?.finishTabDrag()
        }
    }

    private func scheduleTabBarCleanup() {
        tabDragCleanupTask?.cancel()
        tabDragCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.finishTabDrag()
        }
    }

    private func finishTabDrag() {
        tabDragCleanupTask = nil
        temporarilyShownTabBars.removeAll()

        // A successful destination now has 2+ tabs and keeps its native strip. All
        // untouched targets, and a source reduced to one tab, return to the required
        // one-tab/no-strip presentation.
        for window in NSApplication.shared.windows where
            window.isVisible && window.tabbingIdentifier == Self.tabbingIdentifier
        {
            let tabCount = window.tabGroup?.windows.count ?? 1
            if tabCount <= 1, window.tabGroup?.isTabBarVisible == true {
                withoutTabBarAnimation { window.toggleTabBar(nil) }
            }
        }
    }

    private func withoutTabBarAnimation(_ action: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        action()
        NSAnimationContext.endGrouping()
    }

    /// Creates and attaches a tab without ever presenting it as a standalone window.
    ///
    /// SwiftUI's `openWindow` always orders a new WindowGroup scene onscreen before its
    /// content can report the resulting NSWindow. Attaching at that point is inherently
    /// too late and produces a visible blank-window/focus flash. Here the NSWindow is
    /// constructed hidden, populated, and joined to the tab group before AppKit can draw
    /// it independently.
    func openTab(url: URL?, from parent: NSWindow, inBackground: Bool) {
        let window = makeBrowserWindow(url: url, matching: parent)
        parent.addTabbedWindow(window, ordered: .above)
        parent.tabGroup?.selectedWindow = inBackground ? parent : window
        if !inBackground {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openWindow(url: URL?, from source: NSWindow? = nil) {
        let source = source ?? NSApplication.shared.keyWindow
        let window = makeBrowserWindow(url: url, matching: source)
        if let source {
            // Preserve the source window's dimensions but cascade the new window enough
            // to make the separate-window result visually obvious.
            window.setFrameTopLeftPoint(NSPoint(
                x: source.frame.minX + 22,
                y: source.frame.maxY - 22
            ))
        }
        // This is an explicit request for a separate window (Shift-click or
        // "Open Link in New Window"), so it must not be automatically absorbed into
        // the current tab group when first shown. Once it is onscreen, restore the
        // preferred mode so tabs can still be dragged into or out of this window.
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .preferred
    }

    private func makeBrowserWindow(url: URL?, matching source: NSWindow?) -> NSWindow {
        let destination = BrowserWindowDestination(url: url)
        let contentRect = source.map { $0.contentRect(forFrameRect: $0.frame) }
            ?? NSRect(x: 0, y: 0, width: 1_100, height: 760)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        configure(window: window)
        window.contentViewController = NSHostingController(
            rootView: NativeFoundationView(
                initialURL: destination.url,
                destinationID: destination.id
            )
        )
        if let source {
            // Installing a hosting controller can apply its minimal fitting size.
            // Reassert the source's outer frame after installation so new windows and
            // hidden tab windows start with the exact dimensions of their parent.
            window.setFrame(source.frame, display: false)
        } else {
            window.center()
        }

        let controller = NSWindowController(window: window)
        let identifier = ObjectIdentifier(window)
        windowControllers[identifier] = controller
        closeObservers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windowControllers.removeValue(forKey: identifier)
                if let observer = self.closeObservers.removeValue(forKey: identifier) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        return window
    }
}

private struct NativeFoundationView: View {
    @ObservedObject private var settings = BrowserSettingsStore.shared
    let initialURL: URL?
    let destinationID: UUID

    init(initialURL: URL? = nil, destinationID: UUID = UUID()) {
        self.initialURL = initialURL
        self.destinationID = destinationID
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                BrowserWindowView(initialURL: initialURL, destinationID: destinationID)
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
    @StateObject private var browser: BrowserModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hostWindow: NSWindow?
    let destinationID: UUID

    init(initialURL: URL? = nil, destinationID: UUID = UUID()) {
        _browser = StateObject(wrappedValue: BrowserModel(
            restoredState: NativeTabRestorationState.next(initialURL: initialURL),
            initialURL: initialURL
        ))
        self.destinationID = destinationID
    }

    var body: some View {
        BrowserTabView(browser: browser, chromeTopInset: 0)
        .navigationTitle(browser.title)
        .background(WindowAccessor(window: $hostWindow))
        .onAppear {
            configureNativeTab()
            browser.openInNewTab = { url, background in
                openNativeTab(url: url, inBackground: background)
            }
            browser.openInNewWindow = { url in
                NativeTabCoordinator.shared.openWindow(url: url, from: hostWindow)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomNewTab)) { _ in
            guard controlActiveState == .key else { return }
            openNativeTab(url: nil, inBackground: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomCloseTab)) { _ in
            guard controlActiveState == .key else { return }
            hostWindow?.performClose(nil)
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
        .onChange(of: browser.title) { _, _ in configureNativeTab() }
        .onChange(of: browser.favicon) { _, _ in configureNativeTab() }
        .onChange(of: browser.committedURL) { _, _ in configureNativeTab() }
        .onChange(of: hostWindow) { _, window in
            guard let window else { return }
            NativeTabCoordinator.shared.configure(window: window)
            configureNativeTab()
        }
    }

    /// Stops each tab's network work before the window goes away.
    ///
    /// Closing the window tears down the SwiftUI scene without visiting the tabs, so
    /// without this an in-flight request would keep streaming into a document nobody
    /// can see. `closeSelectedTab()` already does this for one tab.
    private func closeHostWindow() {
        browser.stop()
        hostWindow?.performClose(nil)
    }

    private func configureNativeTab() {
        guard let hostWindow else { return }
        NativeTabCoordinator.shared.configure(window: hostWindow)
        hostWindow.title = browser.title
        // Favicons are Unicode glyphs, not bitmap assets. Keeping the favicon and page
        // title in one native string gives both the same font metrics and baseline.
        // NSTextAttachment uses image-cell metrics and pushed the page title visibly
        // below titles on tabs without a favicon.
        hostWindow.tab.attributedTitle = nil
        if let favicon = browser.favicon {
            hostWindow.tab.title = "\(favicon)  \(browser.title)"
        } else {
            hostWindow.tab.title = browser.title
        }
        hostWindow.tab.toolTip = browser.committedURL?.absoluteString ?? browser.title
    }

    private func openNativeTab(url: URL?, inBackground: Bool) {
        guard let hostWindow else {
            NativeTabCoordinator.shared.openWindow(url: url)
            return
        }
        NativeTabCoordinator.shared.openTab(
            url: url,
            from: hostWindow,
            inBackground: inBackground
        )
    }

}

@MainActor
private enum NativeTabRestorationState {
    private static var consumed = false

    static func next(initialURL: URL?) -> RestoredTabState? {
        guard initialURL == nil, !consumed else { return nil }
        consumed = true
        guard let restored = SessionRestorationStore.shared.load(),
              !restored.tabs.isEmpty,
              restored.tabs.indices.contains(restored.selectedIndex) else { return nil }
        return restored.tabs[restored.selectedIndex]
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

            // One slot: the spinner while loading, the capsule's favicon otherwise, which
            // is how Safari uses the same space.
            if browser.isLoading {
                ProgressView().controlSize(.mini)
            } else if let favicon = browser.favicon {
                Text(favicon)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
            }
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
private struct BrowserToolbarButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 38, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(SafariToolbarButtonStyle(isHovered: isHovered, isEnabled: isEnabled))
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = isEnabled && hovering
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isHovered = false }
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

@available(macOS 26.0, *)
private struct SafariToolbarButtonStyle: ButtonStyle {
    let isHovered: Bool
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: .labelColor))
            .opacity(isEnabled ? 0.72 : 0.25)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(isEnabled ? 0.72 : 0.4)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(interactionOpacity(isPressed: configuration.isPressed)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.5)
                    }
            }
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func interactionOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isPressed { return 0.12 }
        return isHovered ? 0.05 : 0
    }
}

@available(macOS 26.0, *)
private struct BrowserTabView: View {
    @ObservedObject var browser: BrowserModel
    let chromeTopInset: CGFloat
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject private var bookmarks = BookmarksModel.shared
    @ObservedObject private var settings = BrowserSettingsStore.shared
    @FocusState private var locationIsFocused: Bool
    @State private var showsFind = false
    @State private var contextMenuMonitor: Any?
    @State private var addBookmarkTarget: AddBookmarkTarget?

    /// Identifies the sheet rather than the bookmark: a fresh id each time means invoking
    /// Add Bookmark twice for the same page still re-presents it.
    private struct AddBookmarkTarget: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
    }
    /// Measured height of the floating chrome, used to keep the find bar clear of it.
    /// Measured rather than hard-coded because the chrome grows when a validation
    /// message appears beneath the toolbar.
    @State private var chromeHeight: CGFloat = 0

    /// Menu commands are broadcast application-wide, so every window's selected tab
    /// receives them. Only the key window's tab may act, or one Command-R reloads
    /// every open window and one Command-S opens a save panel per window.
    private var isKeyWindow: Bool { controlActiveState == .key }

    var body: some View {
        ZStack(alignment: .top) {
            if let internalPage = browser.internalPage {
                // One of Major Tom's own pages: a native view stands in for the web view,
                // inset to clear the floating chrome since it does not scroll under it.
                switch internalPage {
                case .bookmarks:
                    BookmarksManagerView(bookmarks: bookmarks) { url, inNewTab in
                        openBookmark(url, inNewTab: inNewTab)
                    }
                    .padding(.top, chromeHeight)
                }
            } else {
                StreamingWebViewPrototype(browser: browser, findNavigatorIsPresented: $showsFind)
                // WebKit anchors the find bar to the top of the web view. The web view
                // deliberately extends up underneath the floating chrome, so the bar was
                // landing on top of the tab strip and toolbar. Insetting the web view
                // while the bar is open drops it just below the toolbar instead.
                .padding(.top, showsFind ? chromeHeight : 0)
                .animation(.easeOut(duration: 0.15), value: showsFind)
                .dropDestination(for: URL.self) { urls, _ in
                    // A dropped file becomes a file:// page, as in Safari. A dropped
                    // gemini address is navigated to, which is what dragging a link
                    // anywhere else on the Mac does.
                    if let file = urls.first(where: \.isFileURL) {
                        browser.openFile(file)
                        return true
                    }
                    if let capsule = urls.first(where: { $0.scheme?.lowercased() == "gemini" }) {
                        browser.locationText = capsule.absoluteString
                        browser.submitLocation()
                        return true
                    }
                    return false
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
                            .accessibilityLabel(hovered)
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
            }

            VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Safari's navigation glyphs gain a quiet rounded background only on
                // hover. Disabled history directions stay visibly muted and never
                // acquire that hover treatment.
                HStack(spacing: 2) {
                    BrowserToolbarButton(
                        title: "Back",
                        systemImage: "chevron.left",
                        isEnabled: browser.canGoBack,
                        action: browser.goBack
                    )
                    BrowserToolbarButton(
                        title: "Forward",
                        systemImage: "chevron.right",
                        isEnabled: browser.canGoForward,
                        action: browser.goForward
                    )
                }
                .fixedSize()

                BrowserToolbarButton(
                    title: "Home",
                    systemImage: "house",
                    action: browser.goHome
                )

                // Safari puts page-level information behind a control at the leading edge
                // of the address field; info.circle is the system's idiom for it.
                BrowserToolbarButton(
                    title: "Page Information",
                    systemImage: "info.circle",
                    isEnabled: browser.committedURL != nil,
                    action: browser.showPageInformation
                )

                // The capsule's favicon, immediately left of the address it belongs to.
                if let favicon = browser.favicon {
                    Text(favicon)
                        .font(.system(size: 15))
                        .transition(.opacity)
                        .accessibilityLabel("Capsule favicon \(favicon)")
                }

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
                    BrowserToolbarButton(
                        title: "Stop Loading",
                        systemImage: "xmark",
                        action: browser.stop
                    )
                } else {
                    BrowserToolbarButton(
                        title: "Reload Page",
                        systemImage: "arrow.clockwise",
                        isEnabled: browser.canReload,
                        action: browser.reload
                    )
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

                if settings.preferences.showsFavoritesBar {
                    Divider()
                    FavoritesBar(bookmarks: bookmarks) { url, inNewTab in
                        openBookmark(url, inNewTab: inNewTab)
                    }
                }

                Divider()
            }
            .background(.ultraThinMaterial)
            .padding(.top, chromeTopInset)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                chromeHeight = height
            }
        }
        .task { browser.start() }
        .task { await browser.releaseWebViewDragTypes() }
        .onAppear { installContextMenuMonitor() }
        .onDisappear { removeContextMenuMonitor() }
        .onCommand(.majorTomFocusLocation, when: isKeyWindow) { locationIsFocused = true }
        .onCommand(.majorTomReload, when: isKeyWindow) { browser.reload() }
        .onCommand(.majorTomStop, when: isKeyWindow) { browser.stop() }
        .onCommand(.majorTomShowSource, when: isKeyWindow) { browser.showPageSource() }
        .onCommand(.majorTomArchive, when: isKeyWindow) { browser.openArchive() }
        .onCommand(.majorTomAddBookmark, when: isKeyWindow) { requestAddBookmark() }
        .onCommand(.majorTomShowBookmarks, when: isKeyWindow) { browser.showInternalPage(.bookmarks) }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomOpenBookmark)) { notification in
            guard isKeyWindow, let url = notification.object as? URL else { return }
            openBookmark(url, inNewTab: false)
        }
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
        .sheet(item: $addBookmarkTarget) { target in
            AddBookmarkView(
                url: target.url,
                suggestedTitle: target.title,
                bookmarks: bookmarks
            ) {
                addBookmarkTarget = nil
            }
        }
        .sheet(item: $browser.pageInformation) { information in
            PageInfoView(information: information) { browser.pageInformation = nil }
        }
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

    /// Offers to bookmark the page on screen.
    ///
    /// Major Tom's own pages are excluded: `about:bookmarks` is reachable from the menu,
    /// and a bookmark to the bookmark manager is noise.
    private func requestAddBookmark() {
        guard let url = browser.committedURL, InternalPage.page(for: url) == nil else { return }
        addBookmarkTarget = AddBookmarkTarget(url: url, title: browser.title)
    }

    private func openBookmark(_ url: URL, inNewTab: Bool) {
        if inNewTab {
            browser.openInNewTab?(url, true)
            return
        }
        browser.locationText = url.absoluteString
        browser.submitLocation()
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

/// Receives menu actions that have to be delivered through AppKit's target/action rather
/// than a SwiftUI `Button`.
@MainActor
private final class MenuCommandRelay: NSObject {
    @objc func closeTab(_ sender: Any?) {
        NotificationCenter.default.post(name: .majorTomCloseTab, object: nil)
    }
}

/// Turns the standard File ▸ Close item into this app's Close Tab command.
///
/// SwiftUI injects a Close item for a `WindowGroup`, bound to ⌘W and to
/// `performClose:`. Keeping that item is the right call — it is where a Mac user looks —
/// but its title and its action are both wrong for a tabbed browser: `performClose:`
/// closes the whole window, so retitling alone would produce a "Close Tab" that discards
/// every tab in the window. Both are changed together.
///
/// Re-applied whenever a window becomes key, because SwiftUI rebuilds the main menu as
/// scenes change and would otherwise restore the original title and action. Idempotent, so
/// repeating it costs nothing.
@MainActor
private enum FileMenuCustomization {
    /// Menu items do not retain their target, so the relay has to be owned here.
    private static let relay = MenuCommandRelay()

    static func apply() {
        guard let fileMenu = NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu else {
            return
        }
        // Matched on the action selector rather than the title, since titles are localised
        // and this one is about to be replaced anyway.
        for item in fileMenu.items where item.action == #selector(NSWindow.performClose(_:)) {
            item.title = "Close Tab"
            item.target = relay
            item.action = #selector(MenuCommandRelay.closeTab(_:))
            item.keyEquivalent = "w"
            item.keyEquivalentModifierMask = [.command]
        }
    }
}

/// Major Tom uses AppKit's native window tabs exclusively. The native tab bar itself
/// remains available when multiple tabs exist, but the user should not be able to toggle
/// it into a second, competing presentation from the View menu.
@MainActor
private enum NativeTabMenuCustomization {
    private static let observer = NativeTabMenuObserver()
    private static var isInstalled = false

    static func install() {
        apply()
        guard !isInstalled else { return }
        isInstalled = true

        // SwiftUI and AppKit can rebuild or mutate standard menu items after launch.
        // Filter additions/changes immediately, and filter once more before a menu is
        // tracked so neither title can ever become visible to the user.
        for name in [
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
            NSMenu.didBeginTrackingNotification
        ] {
            NotificationCenter.default.addObserver(
                observer,
                selector: #selector(NativeTabMenuObserver.menuChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    static func apply() {
        guard let viewMenu = NSApplication.shared.mainMenu?.item(withTitle: "View")?.submenu else {
            return
        }
        removeTabBarToggle(from: viewMenu)
    }

    fileprivate static func removeTabBarToggle(from menu: NSMenu) {
        // The selector is stable across Show/Hide state and localisation; matching the
        // visible English title was why the old one-shot removal kept losing this race.
        for item in menu.items where item.action == #selector(NSWindow.toggleTabBar(_:)) {
            menu.removeItem(item)
        }
    }
}

@MainActor
private final class NativeTabMenuObserver: NSObject {
    @objc func menuChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        NativeTabMenuCustomization.removeTabBarToggle(from: menu)
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
    static let majorTomAbout = Notification.Name("MajorTomAbout")
    static let majorTomNewTab = Notification.Name("MajorTomNewTab")
    static let majorTomCloseTab = Notification.Name("MajorTomCloseTab")
    static let majorTomCloseWindow = Notification.Name("MajorTomCloseWindow")
    static let majorTomCloseAllWindows = Notification.Name("MajorTomCloseAllWindows")
    static let majorTomFocusLocation = Notification.Name("MajorTomFocusLocation")
    static let majorTomReload = Notification.Name("MajorTomReload")
    static let majorTomStop = Notification.Name("MajorTomStop")
    static let majorTomShowSource = Notification.Name("MajorTomShowSource")
    static let majorTomArchive = Notification.Name("MajorTomArchive")
    static let majorTomAddBookmark = Notification.Name("MajorTomAddBookmark")
    static let majorTomShowBookmarks = Notification.Name("MajorTomShowBookmarks")
    static let majorTomOpenBookmark = Notification.Name("MajorTomOpenBookmark")
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
