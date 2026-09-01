import AppKit
import Combine
import MajorTomAppKitSupport
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
    @Environment(\.openWindow) private var openWindow
    /// Observed so the Bookmarks menu lists the current favourites and reflects the
    /// Favourites-bar toggle.
    @ObservedObject private var bookmarks = BookmarksModel.shared
    @ObservedObject private var settings = BrowserSettingsStore.shared

    init() {
        // Starts conflict-safe synchronization of user-established TOFU pins. The actor
        // holding the local trust database remains the transport's immediate authority.
        _ = TrustedIdentityCloudCoordinator.shared
    }

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

                Button("New Tab at the End") {
                    NotificationCenter.default.post(name: .majorTomNewTabAtEnd, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

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

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .majorTomCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Close Other Tabs") {
                    NotificationCenter.default.post(name: .majorTomCloseOtherTabs, object: nil)
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

                Divider()

                Button("Import Data from Other Clients…") {
                    NotificationCenter.default.post(name: .majorTomImportData, object: nil)
                }
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

            CommandMenu("Certificates") {
                Button("Manage Client Certificates…") {
                    NotificationCenter.default.post(
                        name: .majorTomShowClientCertificates,
                        object: nil
                    )
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
                Divider()
                Button("iCloud Tabs…") { openWindow(id: "icloud-tabs") }
            }
        }

        Window("iCloud Tabs", id: "icloud-tabs") {
            ICloudTabsView()
        }
        .defaultSize(width: 620, height: 480)

        Settings {
            BrowserSettingsView()
        }
    }
}

private final class MajorTomApplicationDelegate: NSObject, NSApplicationDelegate {
    private var commandKeyMonitor: Any?
    private var aboutObserver: (any NSObjectProtocol)?
    private var importDataObserver: (any NSObjectProtocol)?
    private var menuObserver: (any NSObjectProtocol)?
    private var openICloudTabObserver: (any NSObjectProtocol)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Native tab dragging is an AppKit window-tabbing feature. Opt in before the
        // first SwiftUI WindowGroup window is created so a tab dragged from any Major
        // Tom window can join another compatible Major Tom window.
        NSWindow.allowsAutomaticWindowTabbing = true

        // Both stores read and decode their whole file inside an actor's initialiser,
        // which runs on whichever thread first touches them. That was the main actor,
        // while the first tab was being created: BrowserModel.init reaches for both. Warm
        // them here instead, before any window exists.
        Task.detached(priority: .utility) {
            _ = SharedTrustedIdentityStore.shared
            _ = SharedFaviconStore.shared
        }
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
        importDataObserver = NotificationCenter.default.addObserver(
            forName: .majorTomImportData,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ImportDataWindowPresenter.show() }
        }
        DispatchQueue.main.async {
            NSApplication.shared.activate()
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            FileMenuCustomization.install()
            MenuBarIconCustomization.install()
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
                MenuBarIconCustomization.apply()
                NativeTabMenuCustomization.apply()
            }
        }
        openICloudTabObserver = NotificationCenter.default.addObserver(
            forName: .majorTomOpenICloudTab,
            object: nil,
            queue: .main
        ) { notification in
            guard let url = notification.object as? URL else { return }
            MainActor.assumeIsolated { NativeTabCoordinator.shared.openCloudTab(url) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ICloudSyncStore.shared.refresh()
    }


    /// Safari also navigates with Command-Left/Right. There is no way to express a
    /// second key equivalent for one SwiftUI command, so this is an application-wide
    /// monitor that posts the same notification the History menu posts. It lives on
    /// the delegate rather than on each tab view: a per-view monitor was installed
    /// once per open window, so every window reacted to one key press.
    private func installCommandKeyMonitor() {
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Tab overview is AppKit-owned, but Escape is Major Tom's explicit
            // cancellation shortcut for it. Handle it before command navigation so
            // the overview can be dismissed even while its auxiliary Exit panel is
            // the key window.
            if event.keyCode == 53 {
                let didExitTabOverview = MainActor.assumeIsolated { () -> Bool in
                    guard #available(macOS 26.0, *) else { return false }
                    return NativeTabCoordinator.shared.exitTabOverviewIfVisible()
                }
                if didExitTabOverview {
                    return nil
                }
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = event.keyCode
            let hasCommandOnly = modifiers.contains(.command)
                && modifiers.isDisjoint(with: [.shift, .option, .control])

            // AppKit's native WindowGroup responder still treats Command-W as a window
            // close even after its generated File-menu item is removed. Intercept the
            // browser's tab shortcuts before they can reach that responder. Leave the
            // Shift variants alone for Close Window and Close All Windows.
            let isBrowserWindow = MainActor.assumeIsolated {
                NSApplication.shared.keyWindow?.tabbingIdentifier
                    == NativeTabCoordinator.tabbingIdentifier
            }
            let hasCommandAndOptionalOption = modifiers.contains(.command)
                && modifiers.isDisjoint(with: [.shift, .control])
            if isBrowserWindow,
               hasCommandAndOptionalOption,
               let character = event.charactersIgnoringModifiers?.lowercased(),
               character == "t" || character == "w" {
                let usesOption = modifiers.contains(.option)
                let name: Notification.Name
                switch (character, usesOption) {
                case ("t", false): name = .majorTomNewTab
                case ("t", true): name = .majorTomNewTabAtEnd
                case ("w", false): name = .majorTomCloseTab
                default: name = .majorTomCloseOtherTabs
                }
                NotificationCenter.default.post(name: name, object: nil)
                return nil
            }

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

    func applicationWillTerminate(_ notification: Notification) {
        if #available(macOS 26.0, *) {
            NativeTabCoordinator.shared.persistSession()
        }
        // Preferences and history coalesce their writes, so a change made moments before
        // quitting may still be waiting. Flush both rather than lose it.
        BrowserSettingsStore.shared.flushPendingWrites()
        BrowsingHistoryStore.shared.flushPendingWrites()
    }

    /// AppKit sends this responder-chain action when the native tab bar's plus button
    /// is clicked. SwiftUI's WindowGroup previously answered it by presenting a new
    /// standalone scene, which is also the path that caused the visible window flash.
    /// Route the native control through the same hidden-window attachment used by
    /// Command-T and link activation instead.
    @IBAction func newWindowForTab(_ sender: Any?) {
        guard #available(macOS 26.0, *) else { return }
        NativeTabCoordinator.shared.openTabFromNativeControl()
    }

}

@available(macOS 26.0, *)
@MainActor
private final class NativeTabCoordinator {
    static let shared = NativeTabCoordinator()
    static let tabbingIdentifier = "com.acidus.majortom.browser"

    private struct RegisteredTab {
        weak var window: NSWindow?
        weak var browser: BrowserModel?
        let cloudID: UUID
    }

    /// Windows created outside SwiftUI's WindowGroup need a retained controller.
    /// Keeping the controller (rather than only the window) also gives AppKit the
    /// normal ownership relationship it expects for a manually-created window.
    private var windowControllers: [ObjectIdentifier: NSWindowController] = [:]
    private var closeObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]
    /// One tab-bar controller per browser window. AppKit swaps the selected window's
    /// title-bar chrome along with the tab, so every peer needs the same tab-bar policy.
    private var tabOverviewControls: [ObjectIdentifier: PermanentTabOverviewControl] = [:]
    private var registeredTabs: [ObjectIdentifier: RegisteredTab] = [:]
    private var hasAttemptedSessionRestore = false
    private var tabDragMonitor: Any?
    private weak var tabDragCandidateWindow: NSWindow?
    private var tabDragStartPoint: NSPoint?
    private var tabDragTrackingTimer: Timer?
    private var temporarilyShownTabBars: [NSWindow] = []
    private var tabDragCleanupTask: Task<Void, Never>?
    private var cloudPublishTask: Task<Void, Never>?
    private var cloudHeartbeat: Timer?

    private init() {
        tabDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handleTabDragEvent(event)
            return event
        }
        cloudHeartbeat = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.publishCloudTabs() }
        }
    }

    func configure(window: NSWindow) {
        // AppKit uses a matching, non-empty identifier to decide whether windows can
        // accept one another's tabs during a native tab drag.
        // Every tab is its own NSWindow. SwiftUI gives its initial scene a full-size
        // content view automatically, but manually-created tab/window peers do not get
        // that style unless it is applied explicitly. Without it, AppKit composites the
        // native title and tab bars over the default window background instead of the
        // content-theme color, losing the Liquid Glass continuation seen on the first
        // tab.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        prepareTabOverviewControl(on: window)
    }

    /// Creates the window's control once. The native tab bar is lazy, so attachment is
    /// completed once when the window first joins a multi-tab group.
    private func prepareTabOverviewControl(on window: NSWindow) {
        window.tab.accessoryView = nil

        let identifier = ObjectIdentifier(window)
        guard tabOverviewControls[identifier] == nil else { return }

        tabOverviewControls[identifier] = PermanentTabOverviewControl(window: window)
    }

    private func attachPreparedTabOverviewControls(in windows: [NSWindow]) {
        for window in windows {
            prepareTabOverviewControl(on: window)
            tabOverviewControls[ObjectIdentifier(window)]?.attachToTabBarOnce()
        }
    }

    func toggleTabOverview(from window: NSWindow?) {
        // WindowAccessor can briefly be nil while SwiftUI reconstructs browser chrome
        // (notably after an appearance change). The toolbar action must remain enabled
        // and use the same interactive-glass treatment as Reload, so resolve the
        // current key window at activation time instead of disabling the control.
        guard let window = (window ?? NSApplication.shared.keyWindow)?
            .tabGroup?.selectedWindow ?? (window ?? NSApplication.shared.keyWindow) else { return }
        prepareTabOverviewControl(on: window)
        tabOverviewControls[ObjectIdentifier(window)]?.toggleOverview()
    }

    /// AppKit lazily creates each tab window's title-bar hierarchy the first time that
    /// peer is selected. Materialize every peer synchronously inside one non-animated
    /// transaction, attach its already-created control, and leave only the requested
    /// peer selected before AppKit gets another display cycle.
    private func prepareTabChrome(in windows: [NSWindow], selecting selectedWindow: NSWindow) {
        guard let tabGroup = selectedWindow.tabGroup else {
            attachPreparedTabOverviewControls(in: windows)
            return
        }
        withoutTabBarAnimation {
            for window in windows {
                tabGroup.selectedWindow = window
                window.layoutIfNeeded()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                attachPreparedTabOverviewControls(in: [window])
            }
            tabGroup.selectedWindow = selectedWindow
            selectedWindow.layoutIfNeeded()
            selectedWindow.contentView?.superview?.layoutSubtreeIfNeeded()
        }
    }

    func register(window: NSWindow, browser: BrowserModel) {
        configure(window: window)
        let identifier = ObjectIdentifier(window)
        registeredTabs[identifier] = RegisteredTab(
            window: window,
            browser: browser,
            cloudID: registeredTabs[identifier]?.cloudID ?? UUID()
        )
        installCloseObserver(for: window)
        scheduleCloudTabPublish()

        guard !hasAttemptedSessionRestore else { return }
        hasAttemptedSessionRestore = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.restorePendingSession(from: window)
        }
    }

    /// Makes a one-tab window a native drop destination while another native tab is
    /// being dragged. AppKit only accepts a tab drop on a visible tab strip, so the
    /// otherwise-hidden singleton strips are exposed for the duration of the drag.
    private func handleTabDragEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            tabDragCleanupTask?.cancel()
            tabDragCleanupTask = nil
            stopTabDragTracking()
            if !temporarilyShownTabBars.isEmpty { finishTabDrag() }
            let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow)
                ?? NSEvent.mouseLocation
            guard let source = tabbedBrowserWindow(for: event, at: screenPoint),
                  isOnNativeTabButton(screenPoint, of: source) else { return }

            tabDragCandidateWindow = source
            tabDragStartPoint = screenPoint
            beginTabDragTracking()

        case .leftMouseUp:
            stopTabDragTracking()
            if !temporarilyShownTabBars.isEmpty {
                scheduleTabBarCleanup()
            }

        default:
            break
        }
    }

    private func beginTabDragTracking() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTabDrag() }
        }
        tabDragTrackingTimer = timer
        // Native tab controls enter AppKit's private event-tracking run-loop mode. A
        // common-mode timer keeps observing pointer movement there even though AppKit
        // consumes the ordinary leftMouseDragged events.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollTabDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            stopTabDragTracking()
            if !temporarilyShownTabBars.isEmpty { scheduleTabBarCleanup() }
            return
        }
        guard temporarilyShownTabBars.isEmpty,
              let source = tabDragCandidateWindow,
              let start = tabDragStartPoint else { return }
        let current = NSEvent.mouseLocation
        guard hypot(current.x - start.x, current.y - start.y) >= 5 else { return }
        exposeSingletonTabBars(except: source)
    }

    private func stopTabDragTracking() {
        tabDragTrackingTimer?.invalidate()
        tabDragTrackingTimer = nil
        tabDragCandidateWindow = nil
        tabDragStartPoint = nil
    }

    private func tabbedBrowserWindow(for event: NSEvent, at screenPoint: NSPoint) -> NSWindow? {
        // Ordinary content and chrome events identify their owning browser window.
        // Treat that answer as authoritative even when it is not a valid source: if a
        // one-tab foreground window overlaps a multi-tab window, falling through to a
        // frame search would incorrectly start a drag from the obscured window.
        if let eventWindow = event.window,
           eventWindow.tabbingIdentifier == Self.tabbingIdentifier {
            return isValidTabDragSource(eventWindow) ? eventWindow : nil
        }

        // AppKit's private native-tab controls can deliver an event through an
        // auxiliary window. In that case resolve only the frontmost window hit at the
        // pointer, never an arbitrary overlapping browser window farther back.
        let frontmostNumber = NSWindow.windowNumber(
            at: screenPoint,
            belowWindowWithWindowNumber: 0
        )
        guard let frontmost = NSApplication.shared.windows.first(where: {
            $0.windowNumber == frontmostNumber
        }) else { return nil }
        return isValidTabDragSource(frontmost) ? frontmost : nil
    }

    private func isValidTabDragSource(_ window: NSWindow) -> Bool {
        guard window.isVisible,
              !window.isMiniaturized,
              window.tabbingIdentifier == Self.tabbingIdentifier,
              let tabbedWindows = window.tabbedWindows else { return false }

        // Keep passive mouse-event hit testing away from the lazily-created `tabGroup`.
        // AppKit documents `tabbedWindows` as nil when no tab bar is being shown, which
        // is exactly the distinction needed here without requesting a group object.
        return tabbedWindows.count >= 2
    }

    private func isOnNativeTabButton(_ screenPoint: NSPoint, of window: NSWindow) -> Bool {
        guard window.tabbingIdentifier == Self.tabbingIdentifier else { return false }

        // Do not infer the native tab row from title-bar geometry. Full-size content
        // extends behind the title bar, and that made ordinary page clicks look like
        // tab clicks. Compare against the actual on-screen frames of AppKit's native
        // NSTabButton views. Unlike `hitTest`, this remains reliable while AppKit is
        // transferring the press into its private tab-drag tracking loop.
        return NativeTabHitTesting.isOnTabButton(screenPoint: screenPoint, in: window)
    }

    private func exposeSingletonTabBars(except source: NSWindow) {
        for window in NSApplication.shared.windows where
            window !== source
                && window.isVisible
                && !window.isMiniaturized
                && window.tabbingIdentifier == Self.tabbingIdentifier
        {
            // A nil `tabbedWindows` means this is currently a no-strip singleton. Keep
            // this passive scan from requesting AppKit's lazily-created `tabGroup`.
            guard window.tabbedWindows == nil else { continue }
            withoutTabBarAnimation { window.toggleTabBar(nil) }
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            temporarilyShownTabBars.append(window)
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
        stopTabDragTracking()
        temporarilyShownTabBars.removeAll()

        // A successful destination now has 2+ tabs and keeps its native strip. All
        // untouched targets, and a source reduced to one tab, return to the required
        // one-tab/no-strip presentation.
        for window in NSApplication.shared.windows where
            window.isVisible && window.tabbingIdentifier == Self.tabbingIdentifier
        {
            if let tabbedWindows = window.tabbedWindows, tabbedWindows.count <= 1 {
                withoutTabBarAnimation { window.toggleTabBar(nil) }
            }
        }
        attachPreparedTabOverviewControls(in: registeredTabs.values.compactMap(\.window))
    }

    private func withoutTabBarAnimation(_ action: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        action()
        NSAnimationContext.endGrouping()
    }

    func persistSession() {
        let liveTabs = registeredTabs.filter { $0.value.window != nil && $0.value.browser != nil }
        registeredTabs = liveTabs

        let registeredWindows = liveTabs.values.compactMap(\.window)
        let orderedWindows = NSApplication.shared.orderedWindows
            + registeredWindows.filter { candidate in
                !NSApplication.shared.orderedWindows.contains(where: { $0 === candidate })
            }
        var seenGroups = Set<ObjectIdentifier>()
        var windows: [RestoredBrowserWindowState] = []
        var groupKeys: [ObjectIdentifier] = []

        for candidate in orderedWindows where candidate.tabbingIdentifier == Self.tabbingIdentifier {
            let tabWindows = candidate.tabGroup?.windows ?? [candidate]
            let groupKey = candidate.tabGroup.map(ObjectIdentifier.init)
                ?? ObjectIdentifier(candidate)
            guard seenGroups.insert(groupKey).inserted else { continue }

            let states: [(window: NSWindow, state: RestoredTabState)] = tabWindows.compactMap { window in
                guard let browser = registeredTabs[ObjectIdentifier(window)]?.browser else { return nil }
                return (window, browser.restorationState)
            }
            guard !states.isEmpty else { continue }
            let selectedWindow = candidate.tabGroup?.selectedWindow ?? candidate
            let selectedIndex = states.firstIndex { $0.window === selectedWindow } ?? 0
            windows.append(RestoredBrowserWindowState(
                frame: selectedWindow.frame,
                tabs: states.map(\.state),
                selectedIndex: selectedIndex
            ))
            groupKeys.append(groupKey)
        }

        let keyWindow = NSApplication.shared.keyWindow
        let keyGroup = keyWindow.map { window in
            window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
        }
        let keyWindowIndex = keyGroup.flatMap { groupKeys.firstIndex(of: $0) } ?? 0
        SessionRestorationStore.shared.saveApplication(RestoredApplicationState(
            windows: windows,
            keyWindowIndex: keyWindowIndex
        ))
    }

    private func restorePendingSession(from rootWindow: NSWindow) {
        guard let session = NativeTabRestorationState.takePendingApplicationState(),
              !session.windows.isEmpty else { return }

        let first = session.windows[0]
        applySavedFrame(first.frame, to: rootWindow)
        let firstSelectedWindow = restoreTabs(in: first, around: rootWindow)

        var restoredSelections = [firstSelectedWindow]
        for savedWindow in session.windows.dropFirst() where !savedWindow.tabs.isEmpty {
            let window = makeBrowserWindow(
                url: nil,
                matching: nil,
                restoredState: savedWindow.tabs[0]
            )
            applySavedFrame(savedWindow.frame, to: window)
            let selectedWindow = restoreTabs(in: savedWindow, around: window)
            // Explicitly keep each restored group separate while it is first ordered;
            // afterward it remains fully compatible with native tab dragging.
            selectedWindow.tabbingMode = .disallowed
            selectedWindow.orderFront(nil)
            selectedWindow.tabbingMode = .preferred
            restoredSelections.append(selectedWindow)
        }

        let keyIndex = min(max(session.keyWindowIndex, 0), restoredSelections.count - 1)
        restoredSelections[keyIndex].makeKeyAndOrderFront(nil)
        for selectedWindow in restoredSelections {
            attachPreparedTabOverviewControls(
                in: selectedWindow.tabGroup?.windows ?? [selectedWindow]
            )
        }
    }

    private func restoreTabs(
        in savedWindow: RestoredBrowserWindowState,
        around root: NSWindow
    ) -> NSWindow {
        guard !savedWindow.tabs.isEmpty else { return root }
        let selectedIndex = min(max(savedWindow.selectedIndex, 0), savedWindow.tabs.count - 1)
        var windows = [root]
        for state in savedWindow.tabs.dropFirst() {
            windows.append(makeBrowserWindow(
                url: nil,
                matching: root,
                restoredState: state
            ))
        }
        guard windows.count > 1 else { return root }

        // addTabbedWindow inserts immediately after the receiver. Add peers from the
        // saved trailing edge back toward the root to obtain the saved A/B/C order
        // without moving or reinserting any already-hosted NSWindow.
        for window in windows.dropFirst().reversed() {
            root.addTabbedWindow(window, ordered: .above)
        }
        let selectedWindow = windows[selectedIndex]
        prepareTabChrome(in: windows, selecting: selectedWindow)
        return selectedWindow
    }

    private func applySavedFrame(_ frame: CGRect?, to window: NSWindow) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        window.setFrame(frame, display: false)
    }

    private func installCloseObserver(for window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard closeObservers[identifier] == nil else { return }
        closeObservers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.registeredTabs.removeValue(forKey: identifier)
                self.windowControllers.removeValue(forKey: identifier)
                self.tabOverviewControls.removeValue(forKey: identifier)
                if let observer = self.closeObservers.removeValue(forKey: identifier) {
                    NotificationCenter.default.removeObserver(observer)
                }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self else { return }
                    if let window {
                        self.attachPreparedTabOverviewControls(in: window.tabGroup?.windows ?? [window])
                    }
                    self.persistSession()
                }
                self.scheduleCloudTabPublish()
            }
        }
    }

    /// Creates and attaches a tab without ever presenting it as a standalone window.
    ///
    /// SwiftUI's `openWindow` always orders a new WindowGroup scene onscreen before its
    /// content can report the resulting NSWindow. Attaching at that point is inherently
    /// too late and produces a visible blank-window/focus flash. Here the NSWindow is
    /// constructed hidden, populated, and joined to the tab group before AppKit can draw
    /// it independently.
    func openTab(
        url: URL?,
        from parent: NSWindow,
        inBackground: Bool,
        atEnd: Bool = false
    ) {
        let window = makeBrowserWindow(
            url: url,
            matching: parent,
            focusesLocationOnPresentation: url == nil && !inBackground
        )
        let insertionAnchor = atEnd
            ? NativeTabOrdering.endInsertionAnchor(for: parent)
            : parent
        insertionAnchor.addTabbedWindow(window, ordered: .above)
        let selectedWindow = inBackground ? parent : window
        prepareTabChrome(
            in: window.tabGroup?.windows ?? [parent, window],
            selecting: selectedWindow
        )
        if !inBackground {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func closeOtherTabs(keeping selectedWindow: NSWindow) {
        let otherWindows = (selectedWindow.tabGroup?.windows ?? [selectedWindow]).filter {
            $0 !== selectedWindow
        }
        for window in otherWindows {
            registeredTabs[ObjectIdentifier(window)]?.browser?.stop()
            window.performClose(nil)
        }
        selectedWindow.makeKeyAndOrderFront(nil)
    }

    func openTabFromNativeControl() {
        let registeredWindows = registeredTabs.values.compactMap(\.window)
        let keyBrowserWindow = NSApplication.shared.keyWindow.flatMap { keyWindow in
            registeredTabs[ObjectIdentifier(keyWindow)] == nil ? nil : keyWindow
        }
        let overviewWindow = registeredWindows.first(where: {
            $0.tabGroup?.isOverviewVisible == true
        })
        let parent = keyBrowserWindow
            ?? overviewWindow?.tabGroup?.selectedWindow
            ?? overviewWindow
            ?? registeredWindows.first(where: \.isVisible)
        guard let parent else { return }
        openTab(url: nil, from: parent, inBackground: false)
    }

    /// Returns whether Escape dismissed an active native overview. Locating the
    /// overview through registered browser windows (rather than `keyWindow`) matters
    /// because the nonactivating Exit panel may temporarily be the key window.
    func exitTabOverviewIfVisible() -> Bool {
        guard let overviewWindow = registeredTabs.values.compactMap(\.window).first(where: {
            $0.tabGroup?.isOverviewVisible == true
        }) else {
            return false
        }
        (overviewWindow.tabGroup?.selectedWindow ?? overviewWindow).toggleTabOverview(nil)
        return true
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

    func openCloudTab(_ url: URL) {
        let keyBrowserWindow = NSApplication.shared.keyWindow.flatMap { window in
            registeredTabs[ObjectIdentifier(window)]?.browser == nil ? nil : window
        }
        if let parent = keyBrowserWindow ?? registeredTabs.values.compactMap(\.window).first {
            openTab(url: url, from: parent, inBackground: false)
        } else {
            openWindow(url: url)
        }
    }

    func scheduleCloudTabPublish() {
        cloudPublishTask?.cancel()
        cloudPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.publishCloudTabs()
        }
    }

    private func publishCloudTabs() {
        let tabs = registeredTabs.values.compactMap { registration -> CloudTabSnapshot? in
            guard let browser = registration.browser,
                  let url = browser.committedURL,
                  ["gemini", "http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return CloudTabSnapshot(
                id: registration.cloudID,
                title: browser.title,
                url: url
            )
        }
        ICloudSyncStore.shared.updateTabs(tabs)
    }

    private func makeBrowserWindow(
        url: URL?,
        matching source: NSWindow?,
        restoredState: RestoredTabState? = nil,
        focusesLocationOnPresentation: Bool = false
    ) -> NSWindow {
        let destination = BrowserWindowDestination(url: url)
        if let restoredState {
            NativeTabRestorationState.enqueue(restoredState, for: destination.id)
        }
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
                destinationID: destination.id,
                focusesLocationOnPresentation: focusesLocationOnPresentation
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
        installCloseObserver(for: window)
        return window
    }
}

@available(macOS 26.0, *)
private final class NotificationObserverToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }
}

@available(macOS 26.0, *)
private final class KeyValueObserverToken: @unchecked Sendable {
    let value: NSKeyValueObservation

    init(_ value: NSKeyValueObservation) {
        self.value = value
    }
}

@available(macOS 26.0, *)
@MainActor
private final class PermanentTabOverviewControl: NSObject {
    private weak var window: NSWindow?
    private weak var tabBar: NSView?
    private weak var tabTrack: NSView?
    private var addTabButton: NSButton?
    private let exitOverviewButton: NSButton
    private let exitOverviewPanel: NSPanel
    private var windowObservers: [NotificationObserverToken] = []
    private var overviewObserver: KeyValueObserverToken?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var nativeTrackToAddConstraint: NSLayoutConstraint?
    private var nativeAddToBarConstraint: NSLayoutConstraint?
    private var expandedTrackConstraint: NSLayoutConstraint?

    init(window: NSWindow) {
        self.window = window
        exitOverviewButton = NSButton(
            image: NSImage(
                systemSymbolName: "square.on.square",
                accessibilityDescription: "Hide Tab Overview"
            )!,
            target: nil,
            action: nil
        )
        exitOverviewPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        exitOverviewButton.target = self
        exitOverviewButton.action = #selector(toggleOverview(_:))
        exitOverviewButton.bezelStyle = .glass
        exitOverviewButton.imagePosition = .imageOnly
        exitOverviewButton.controlSize = .large
        exitOverviewButton.toolTip = "Hide Tab Overview"
        exitOverviewButton.setAccessibilityLabel("Hide Tab Overview")
        exitOverviewPanel.isOpaque = false
        exitOverviewPanel.backgroundColor = .clear
        exitOverviewPanel.hasShadow = false
        exitOverviewPanel.becomesKeyOnlyIfNeeded = true
        exitOverviewPanel.level = .statusBar
        exitOverviewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let exitPanelContent = NSView(frame: exitOverviewPanel.contentView?.bounds ?? .zero)
        exitOverviewButton.frame = exitPanelContent.bounds
        exitOverviewButton.autoresizingMask = [.width, .height]
        exitPanelContent.addSubview(exitOverviewButton)
        exitOverviewPanel.contentView = exitPanelContent

        for name in [NSWindow.didResizeNotification] {
            windowObservers.append(NotificationObserverToken(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.positionExitOverviewPanel() }
                }
            ))
        }
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer.value)
        }
    }

    /// AppKit creates the tab bar lazily when a second NSWindow joins the group. Once it
    /// exists, remove the Add Tab button's two links from the native constraint chain
    /// and connect the tab track directly to the bar's normal trailing inset. The tab
    /// bar itself remains full-width and contains only tabs.
    func attachToTabBarOnce() {
        observeCurrentTabGroup()
        guard let window else { return }
        guard (window.tabbedWindows?.count ?? 1) > 1 else {
            restoreNativeTabBarLayout()
            return
        }
        // Keep the full-width track installed while Tab Overview is visible. AppKit
        // reveals this same tab bar during its exit animation; restoring the native
        // Add-button slot here makes the track visibly grow after the animation.
        guard !(window.tabGroup?.isOverviewVisible ?? false) else { return }
        guard let root = window.contentView?.superview else { return }
        root.layoutSubtreeIfNeeded()

        guard let tabBar = firstDescendant(named: "NSTabBar", in: root),
              let tabTrack = firstDescendant(named: "NSTabBarTrackView", in: tabBar),
              let addButton = tabBar.subviews.compactMap({ $0 as? NSButton }).first(where: {
                  $0.action.map(NSStringFromSelector) == "_newTabWithinWindow:"
              }) else { return }

        if self.tabBar !== tabBar || self.tabTrack !== tabTrack
            || self.addTabButton !== addButton || expandedTrackConstraint == nil {
            restoreNativeTabBarLayout()
            self.tabBar = tabBar
            self.tabTrack = tabTrack
            self.addTabButton = addButton
            guard installTabTrackLayout(in: tabBar, track: tabTrack, addButton: addButton) else {
                self.tabBar = nil
                self.tabTrack = nil
                self.addTabButton = nil
                return
            }
        }
        addButton.isHidden = true
        tabBar.layoutSubtreeIfNeeded()
    }

    private func firstDescendant(named className: String, in view: NSView) -> NSView? {
        if NSStringFromClass(type(of: view)) == className { return view }
        for child in view.subviews {
            if let match = firstDescendant(named: className, in: child) { return match }
        }
        return nil
    }

    private func installTabTrackLayout(
        in tabBar: NSView,
        track: NSView,
        addButton: NSButton
    ) -> Bool {
        guard let trackToAdd = tabBar.constraints.first(where: {
            connects($0, track, .trailing, addButton, .leading)
        }), let addToBar = tabBar.constraints.first(where: {
            connects($0, addButton, .trailing, tabBar, .trailing)
        }) else { return false }

        nativeTrackToAddConstraint = trackToAdd
        nativeAddToBarConstraint = addToBar
        let trailingInset = max(0, tabBar.bounds.maxX - addButton.frame.maxX)
        NSLayoutConstraint.deactivate([trackToAdd, addToBar])
        let expanded = track.trailingAnchor.constraint(
            equalTo: tabBar.trailingAnchor,
            constant: -trailingInset
        )
        expandedTrackConstraint = expanded
        expanded.isActive = true
        addButton.removeFromSuperview()
        return true
    }

    private func connects(
        _ constraint: NSLayoutConstraint,
        _ firstView: NSView,
        _ firstAttribute: NSLayoutConstraint.Attribute,
        _ secondView: NSView,
        _ secondAttribute: NSLayoutConstraint.Attribute
    ) -> Bool {
        let item1 = constraint.firstItem as? NSView
        let item2 = constraint.secondItem as? NSView
        return (item1 === firstView && constraint.firstAttribute == firstAttribute
                && item2 === secondView && constraint.secondAttribute == secondAttribute)
            || (item1 === secondView && constraint.firstAttribute == secondAttribute
                && item2 === firstView && constraint.secondAttribute == firstAttribute)
    }

    private func restoreNativeTabBarLayout() {
        expandedTrackConstraint?.isActive = false
        expandedTrackConstraint = nil
        if let tabBar, let tabTrack, let addTabButton,
           addTabButton.superview == nil {
            tabBar.addSubview(addTabButton, positioned: .above, relativeTo: tabTrack)
        }
        if let nativeTrackToAddConstraint, let nativeAddToBarConstraint {
            NSLayoutConstraint.activate([nativeTrackToAddConstraint, nativeAddToBarConstraint])
        }
        nativeTrackToAddConstraint = nil
        nativeAddToBarConstraint = nil
        tabBar?.layoutSubtreeIfNeeded()
        tabBar = nil
        tabTrack = nil
        addTabButton = nil
    }

    private func observeCurrentTabGroup() {
        guard let tabGroup = window?.tabGroup,
              observedTabGroup !== tabGroup else { return }
        observedTabGroup = tabGroup
        overviewObserver = KeyValueObserverToken(tabGroup.observe(
            \.isOverviewVisible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handleOverviewVisibilityChange() }
        })
    }

    func toggleOverview() {
        toggleOverview(nil)
    }

    @objc private func toggleOverview(_ sender: Any?) {
        guard let window else { return }
        let wasOverviewVisible = window.tabGroup?.isOverviewVisible ?? false
        if wasOverviewVisible {
            hideExitOverviewPanel()
        }
        window.toggleTabOverview(sender)
        observeCurrentTabGroup()
        handleOverviewVisibilityChange()
        if wasOverviewVisible {
            attachToTabBarOnce()
        }
    }

    private func handleOverviewVisibilityChange() {
        let isOverviewVisible = window?.tabGroup?.isOverviewVisible ?? false
        NativeTabMenuCustomization.apply()
        if isOverviewVisible {
            if window?.tabGroup?.selectedWindow === window {
                showExitOverviewPanel()
            }
        } else {
            hideExitOverviewPanel()
            // A tab created from overview does not receive normal title-bar chrome
            // until AppKit completes the overview exit. Refresh the native metrics as
            // that state changes, while keeping the public accessory installed.
            attachToTabBarOnce()
        }
    }

    private func showExitOverviewPanel() {
        guard window?.tabGroup?.isOverviewVisible == true else { return }
        positionExitOverviewPanel()
        exitOverviewPanel.orderFrontRegardless()
    }

    private func positionExitOverviewPanel() {
        guard window?.tabGroup?.isOverviewVisible == true,
              let window else { return }
        let panelSize = exitOverviewPanel.frame.size
        exitOverviewPanel.setFrame(NSRect(
            x: window.frame.maxX - panelSize.width - 16,
            y: window.frame.maxY - panelSize.height - 16,
            width: panelSize.width,
            height: panelSize.height
        ), display: true)
    }

    private func hideExitOverviewPanel() {
        exitOverviewPanel.orderOut(nil)
    }
}

private struct NativeFoundationView: View {
    @ObservedObject private var settings = BrowserSettingsStore.shared
    let initialURL: URL?
    let destinationID: UUID
    let focusesLocationOnPresentation: Bool

    init(
        initialURL: URL? = nil,
        destinationID: UUID = UUID(),
        focusesLocationOnPresentation: Bool = false
    ) {
        self.initialURL = initialURL
        self.destinationID = destinationID
        self.focusesLocationOnPresentation = focusesLocationOnPresentation
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                BrowserWindowView(
                    initialURL: initialURL,
                    destinationID: destinationID,
                    focusesLocationOnPresentation: focusesLocationOnPresentation
                )
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
    @State private var hostWindow: NSWindow?
    let destinationID: UUID
    let focusesLocationOnPresentation: Bool

    init(
        initialURL: URL? = nil,
        destinationID: UUID = UUID(),
        focusesLocationOnPresentation: Bool = false
    ) {
        _browser = StateObject(wrappedValue: BrowserModel(
            restoredState: NativeTabRestorationState.next(
                destinationID: destinationID,
                initialURL: initialURL
            ),
            initialURL: initialURL
        ))
        self.destinationID = destinationID
        self.focusesLocationOnPresentation = focusesLocationOnPresentation
    }

    var body: some View {
        BrowserTabView(
            browser: browser,
            chromeTopInset: 0,
            hostWindow: hostWindow,
            focusesLocationOnPresentation: focusesLocationOnPresentation
        )
        .navigationTitle(browser.title)
        .background(WindowAccessor(window: $hostWindow))
        .onAppear {
            if let hostWindow {
                NativeTabCoordinator.shared.register(window: hostWindow, browser: browser)
            }
            configureNativeTab()
            browser.openInNewTab = { url, background in
                openNativeTab(url: url, inBackground: background)
            }
            browser.openInNewWindow = { url in
                NativeTabCoordinator.shared.openWindow(url: url, from: hostWindow)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomNewTab)) { _ in
            guard isCommandTarget else { return }
            openNativeTab(url: nil, inBackground: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomNewTabAtEnd)) { _ in
            guard isCommandTarget else { return }
            openNativeTab(url: nil, inBackground: false, atEnd: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomCloseTab)) { _ in
            guard isCommandTarget else { return }
            hostWindow?.performClose(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomCloseOtherTabs)) { _ in
            guard isCommandTarget, let hostWindow else { return }
            NativeTabCoordinator.shared.closeOtherTabs(keeping: hostWindow)
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
            NativeTabCoordinator.shared.register(window: window, browser: browser)
            configureNativeTab()
        }
    }

    private var isCommandTarget: Bool {
        NativeTabCommandTarget.isSelectedTab(
            hostWindow,
            keyWindow: NSApplication.shared.keyWindow
        )
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
        NativeTabCoordinator.shared.scheduleCloudTabPublish()
    }

    private func openNativeTab(url: URL?, inBackground: Bool, atEnd: Bool = false) {
        guard let hostWindow else {
            NativeTabCoordinator.shared.openWindow(url: url)
            return
        }
        NativeTabCoordinator.shared.openTab(
            url: url,
            from: hostWindow,
            inBackground: inBackground,
            atEnd: atEnd
        )
    }

}

@MainActor
private enum NativeTabRestorationState {
    private static var consumedInitialTab = false
    private static var pendingApplicationState: RestoredApplicationState?
    private static var queuedTabs: [UUID: RestoredTabState] = [:]

    static func next(destinationID: UUID, initialURL: URL?) -> RestoredTabState? {
        if let queued = queuedTabs.removeValue(forKey: destinationID) { return queued }
        guard initialURL == nil, !consumedInitialTab else { return nil }
        consumedInitialTab = true
        guard let restored = SessionRestorationStore.shared.loadApplication(),
              let firstWindow = restored.windows.first,
              !firstWindow.tabs.isEmpty else { return nil }
        pendingApplicationState = restored
        return firstWindow.tabs[0]
    }

    static func enqueue(_ state: RestoredTabState, for destinationID: UUID) {
        queuedTabs[destinationID] = state
    }

    static func takePendingApplicationState() -> RestoredApplicationState? {
        defer { pendingApplicationState = nil }
        return pendingApplicationState
    }
}

@available(macOS 26.0, *)
private struct BrowserToolbarButtonLabel: View {
    let systemImage: String
    /// A capsule favicon replaces the system glyph while retaining the button's native
    /// hit target, interaction treatment, help text, and accessibility name.
    var favicon: String?

    var body: some View {
        // Keep the conditional inside one concrete label container. Control containers
        // are allowed to flatten a Group's children; doing that here made the fallback
        // info.circle and the favicon appear as two separate controls.
        ZStack {
            if let favicon {
                // Emoji favicons are rendered by Apple Color Emoji, so do not apply
                // a tint that would turn them into a monochrome toolbar glyph.
                Text(favicon)
                    .font(.system(size: 15))
            } else {
                Image(systemName: systemImage)
            }
        }
        .frame(minWidth: 16, minHeight: 16)
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
            BrowserToolbarButtonLabel(systemImage: systemImage)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular
                .tint(isHovered && isEnabled ? Color.primary.opacity(0.08) : nil)
                .interactive(isEnabled),
            in: Circle()
        )
        .disabled(!isEnabled)
        .onHover { hovering in isHovered = isEnabled && hovering }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isHovered = false }
        }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .help(title)
        .accessibilityLabel(title)
    }
}

@available(macOS 26.0, *)
private struct BrowserToolbarSegmentButton: View {
    let title: String
    let systemImage: String
    var favicon: String?
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            BrowserToolbarButtonLabel(systemImage: systemImage, favicon: favicon)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(SafariToolbarSegmentButtonStyle(
            isHovered: isHovered,
            isEnabled: isEnabled,
            preservesFaviconColors: favicon != nil
        ))
        .disabled(!isEnabled)
        .onHover { hovering in isHovered = isEnabled && hovering }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isHovered = false }
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

@available(macOS 26.0, *)
private struct SafariToolbarSegmentButtonStyle: ButtonStyle {
    let isHovered: Bool
    let isEnabled: Bool
    let preservesFaviconColors: Bool

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if preservesFaviconColors {
                configuration.label
            } else {
                configuration.label.foregroundStyle(Color(nsColor: .labelColor))
            }
        }
        .opacity(isEnabled ? 1 : 0.3)
        .background {
            Circle()
                .fill(Color.primary.opacity(interactionOpacity(
                    isPressed: configuration.isPressed
                )))
        }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func interactionOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isPressed { return 0.14 }
        return isHovered ? 0.08 : 0
    }
}

@available(macOS 26.0, *)
private struct BrowserTabView: View {
    @ObservedObject var browser: BrowserModel
    let chromeTopInset: CGFloat
    let hostWindow: NSWindow?
    let focusesLocationOnPresentation: Bool
    @ObservedObject private var bookmarks = BookmarksModel.shared
    @ObservedObject private var settings = BrowserSettingsStore.shared
    @ObservedObject private var clientCertificates = ClientCertificateStore.shared
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
    /// Measured height of the floating chrome, used to position WebKit's native Find
    /// bar immediately below it.
    /// Measured rather than hard-coded because the chrome grows when a validation
    /// message appears beneath the toolbar.
    @State private var chromeHeight: CGFloat = 0

    /// Menu commands are broadcast application-wide. Native AppKit tabs are separate
    /// NSWindows, while SwiftUI reports every member of the key tab group as `.key`.
    /// Compare window identity and native selection at delivery time so exactly one tab
    /// handles each command.
    private var isCommandTarget: Bool {
        NativeTabCommandTarget.isSelectedTab(
            hostWindow,
            keyWindow: NSApplication.shared.keyWindow
        )
    }

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
                case .clientCertificates:
                    ClientCertificatesManagerView(store: clientCertificates) { url in
                        browser.openInNewTab?(url, false)
                    }
                        .padding(.top, chromeHeight)
                }
            } else {
                ZStack {
                    contentThemeBackground
                        .ignoresSafeArea()

                    StreamingWebViewPrototype(
                        browser: browser,
                        findNavigatorIsPresented: $showsFind,
                        scrollerTopInset: chromeHeight
                    )
                        .opacity(
                            browser.hasPresentedInitialDocument
                                && !browser.isRestoringHistoryScroll ? 1 : 0
                        )
                        // Keep document content edge-to-edge beneath the floating chrome,
                        // like Safari. StreamingWebViewPrototype separately insets only
                        // WebKit's scroller so its thumb begins below these controls.
                        .padding(.top, showsFind ? chromeHeight : 0)
                        .animation(.easeOut(duration: 0.15), value: showsFind)
                }
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
                // Safari uses one glass surface with compact independent actions inside
                // it. This avoids the wide spacing and broad sampling region produced by
                // unioning two complete glass buttons.
                HStack(spacing: 0) {
                        BrowserToolbarSegmentButton(
                            title: "Back",
                            systemImage: "chevron.left",
                            isEnabled: browser.canGoBack,
                            action: browser.goBack
                        )
                        .overlay(alignment: .trailing) {
                            Divider()
                                .padding(.vertical, 7)
                                .allowsHitTesting(false)
                        }
                        BrowserToolbarSegmentButton(
                            title: "Forward",
                            systemImage: "chevron.right",
                            isEnabled: browser.canGoForward,
                            action: browser.goForward
                        )
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: Capsule())
                .fixedSize()

                // Home and Page Information both describe or change the current page,
                // so they form a second connected functional group. A capsule favicon
                // personalizes Page Information; info.circle remains its fallback.
                HStack(spacing: 0) {
                        BrowserToolbarSegmentButton(
                            title: "Home",
                            systemImage: "house",
                            action: browser.goHome
                        )
                        BrowserToolbarSegmentButton(
                            title: "Page Information",
                            systemImage: "info.circle",
                            favicon: browser.favicon,
                            isEnabled: browser.committedURL != nil,
                            action: browser.showPageInformation
                        )
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: Capsule())
                .fixedSize()

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
                BrowserToolbarButton(
                    title: "Show Tab Overview",
                    systemImage: "square.on.square",
                    action: {
                        NativeTabCoordinator.shared.toggleTabOverview(from: hostWindow)
                    }
                )
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
                    } openInNewWindow: { url in
                        browser.openInNewWindow?(url)
                    }
                    .frame(height: 28)
                }

                Divider()
            }
            .background(.ultraThinMaterial)
            // WebKit deliberately extends underneath the floating chrome. Give the
            // chrome a concrete interaction plane so AppKit cannot hit-test through
            // transparent parts of the Favorites Bar into the web view.
            .contentShape(Rectangle())
            .zIndex(1)
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
        .onCommand(.majorTomFocusLocation, when: { isCommandTarget }) {
            focusLocationAndSelectAll()
        }
        .onChange(of: hostWindow) { _, window in
            guard focusesLocationOnPresentation, window?.isKeyWindow == true else { return }
            focusLocationAndSelectAll()
        }
        .onCommand(.majorTomReload, when: { isCommandTarget }) { browser.reload() }
        .onCommand(.majorTomStop, when: { isCommandTarget }) { browser.stop() }
        .onCommand(.majorTomShowSource, when: { isCommandTarget }) { browser.showPageSource() }
        .onCommand(.majorTomArchive, when: { isCommandTarget }) { browser.openArchive() }
        .onCommand(.majorTomAddBookmark, when: { isCommandTarget }) { requestAddBookmark() }
        .onCommand(.majorTomShowBookmarks, when: { isCommandTarget }) { browser.showInternalPage(.bookmarks) }
        .onCommand(.majorTomShowClientCertificates, when: { isCommandTarget }) {
            browser.showInternalPage(.clientCertificates)
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomOpenBookmark)) { notification in
            guard isCommandTarget, let url = notification.object as? URL else { return }
            openBookmark(url, inNewTab: false)
        }
        .onCommand(.majorTomSavePage, when: { isCommandTarget }) { Task { await browser.savePage() } }
        .onCommand(.majorTomPrint, when: { isCommandTarget }) { browser.printPage() }
        .onCommand(.majorTomFind, when: { isCommandTarget }) { showsFind = true }
        .onCommand(.majorTomZoomIn, when: { isCommandTarget }) { browser.zoomIn() }
        .onCommand(.majorTomZoomOut, when: { isCommandTarget }) { browser.zoomOut() }
        .onCommand(.majorTomActualSize, when: { isCommandTarget }) { browser.actualSize() }
        .onCommand(.majorTomBack, when: { isCommandTarget }) { browser.goBack() }
        .onCommand(.majorTomForward, when: { isCommandTarget }) { browser.goForward() }
        .onCommand(.majorTomHome, when: { isCommandTarget }) { browser.goHome() }
        .onCommand(.majorTomUp, when: { isCommandTarget }) { browser.goUpOneLevel() }
        .onCommand(.majorTomRoot, when: { isCommandTarget }) { browser.goToCapsuleRoot() }
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
            PageInfoView(
                information: information,
                dismiss: { browser.pageInformation = nil },
                stopUsingClientCertificate: browser.stopUsingClientCertificateForCurrentPage,
                showClientCertificate: {
                    guard let certificate = information.clientCertificate else { return }
                    clientCertificates.requestManagerSelection(certificate.id)
                    browser.pageInformation = nil
                    browser.openInNewTab?(InternalPage.clientCertificates.url, false)
                }
            )
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
                case .dismissed(let draft):
                    browser.preserveInputDraft(draft, for: prompt.target)
                }
            }
        }
        .sheet(item: $browser.clientCertificatePrompt) { prompt in
            ClientCertificatePromptView(
                prompt: prompt,
                store: clientCertificates,
                use: browser.useClientCertificate,
                stopUsing: browser.stopUsingClientCertificateForPendingChallenge,
                cancel: browser.cancelClientCertificatePrompt
            )
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

    /// Gives the native field editor one update cycle to become first responder before
    /// selecting its contents. This also makes Command-L reselect the address when the
    /// location field already owns focus.
    private func focusLocationAndSelectAll() {
        locationIsFocused = true
        Task { @MainActor in
            // SwiftUI updates AppKit's first responder after the FocusState mutation.
            // A few short retries cover that handoff without selecting the old web view
            // if its field editor has not been installed yet.
            for _ in 0..<4 {
                await Task.yield()
                guard locationIsFocused, let hostWindow, hostWindow.isKeyWindow else { return }
                if let editor = hostWindow.firstResponder as? NSTextView,
                   editor.delegate is NSTextField {
                    editor.selectAll(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private var contentThemeBackground: Color {
        let theme = settings.preferences.contentTheme
        let effectiveDarkAppearance = NSApplication.shared.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let background = theme.palette(
            effectiveDarkAppearance: effectiveDarkAppearance
        ).background
        return Color(
            red: Double(background.red) / 255,
            green: Double(background.green) / 255,
            blue: Double(background.blue) / 255
        )
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

/// Removes SwiftUI's trailing window-level Close command and configures the browser's
/// Option-key alternatives. SwiftUI does not expose `NSMenuItem.isAlternate`, so that
/// native menu behavior is applied after its command items are materialized.
@MainActor
private enum FileMenuCustomization {
    private static let observer = FileMenuObserver()
    private static var isInstalled = false
    private static var isApplying = false

    static func install() {
        apply()
        guard !isInstalled else { return }
        isInstalled = true
        for name in [
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
            NSMenu.didBeginTrackingNotification
        ] {
            NotificationCenter.default.addObserver(
                observer,
                selector: #selector(FileMenuObserver.menuChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    static func apply() {
        guard let fileMenu = NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu else {
            return
        }
        apply(to: fileMenu)
    }

    fileprivate static func apply(to fileMenu: NSMenu) {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        // A WindowGroup always contributes its own Close/Close All item at the bottom.
        // Browser tab/window commands are declared explicitly above, so retaining this
        // system item creates a duplicate ⌘W action with the wrong semantics.
        let stockCloseItems = fileMenu.items.filter { item in
            let hasStockTitle = item.title == "Close" || item.title == "Close All"
            let actionName = item.action.map(NSStringFromSelector)
            return actionName == "closeTab:"
                || actionName == "closeAll:"
                || item.action == #selector(NSWindow.performClose(_:))
                || (hasStockTitle && item.keyEquivalent.lowercased() == "w")
        }
        for item in stockCloseItems { fileMenu.removeItem(item) }

        for item in fileMenu.items {
            switch item.title {
            case "New Tab at the End":
                configureAsAlternate(item, key: "t")
            case "Close Other Tabs":
                configureAsAlternate(item, key: "w")
            default:
                break
            }
        }
    }

    private static func configureAsAlternate(_ item: NSMenuItem, key: String) {
        item.isAlternate = true
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = [.command, .option]
    }
}

@MainActor
private final class FileMenuObserver: NSObject {
    @objc func menuChanged(_ notification: Notification) {
        // Main-menu tracking notifications are emitted by the root menu even when its
        // File submenu is the one being opened. Always resolve the current File menu;
        // SwiftUI may have replaced that submenu since the preceding notification.
        FileMenuCustomization.apply()
    }
}

/// Adds the same SF Symbols used by page/link context menus to their menu-bar
/// counterparts. SwiftUI recreates command items as scenes change, so this observes menu
/// construction and also reapplies immediately before a menu begins tracking.
@MainActor
private enum MenuBarIconCustomization {
    private static let observer = MenuBarIconObserver()
    private static var isInstalled = false

    static func install() {
        apply()
        guard !isInstalled else { return }
        isInstalled = true
        for name in [NSMenu.didAddItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(
                observer,
                selector: #selector(MenuBarIconObserver.menuChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    static func apply() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        applyIcons(to: mainMenu)
    }

    fileprivate static func applyIcons(to menu: NSMenu) {
        for item in menu.items {
            if item.image == nil,
               let symbol = BrowserMenuIcon.menuBarSymbolByTitle[item.title] {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)
            }
            if let submenu = item.submenu { applyIcons(to: submenu) }
        }
    }
}

@MainActor
private final class MenuBarIconObserver: NSObject {
    @objc func menuChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        MenuBarIconCustomization.applyIcons(to: menu)
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
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        if let viewMenu = mainMenu.item(withTitle: "View")?.submenu {
            removeTabBarToggle(from: viewMenu)
        }
        renameTabOverviewItems(in: mainMenu)
    }

    fileprivate static func removeTabBarToggle(from menu: NSMenu) {
        // The selector is stable across Show/Hide state and localisation; matching the
        // visible English title was why the old one-shot removal kept losing this race.
        for item in menu.items where item.action == #selector(NSWindow.toggleTabBar(_:)) {
            menu.removeItem(item)
        }
    }

    fileprivate static func renameTabOverviewItems(in menu: NSMenu) {
        let title = isTabOverviewVisible ? "Hide Tab Overview" : "Show Tab Overview"
        for item in menu.items {
            if item.action == #selector(NSWindow.toggleTabOverview(_:)) {
                item.title = title
                item.toolTip = title
            }
            if let submenu = item.submenu {
                renameTabOverviewItems(in: submenu)
            }
        }
    }

    private static var isTabOverviewVisible: Bool {
        NSApplication.shared.windows.contains { $0.tabGroup?.isOverviewVisible == true }
    }
}

@MainActor
private final class NativeTabMenuObserver: NSObject {
    @objc func menuChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        NativeTabMenuCustomization.removeTabBarToggle(from: menu)
        NativeTabMenuCustomization.renameTabOverviewItems(in: menu)
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
    /// The sheet went away without the reader answering it — a navigation elsewhere, or
    /// the window closing. Keeps the draft, but claims none of the status area, loading
    /// state or address field, which now belong to whatever replaced the prompt.
    case dismissed(draft: String)
}

@available(macOS 26.0, *)
private struct CapsuleInputView: View {
    let prompt: BrowserModel.InputPrompt
    let validationMessage: String?
    let completion: (CapsuleInputOutcome) -> Void

    @State private var value: String
    @State private var editorHeight: CGFloat
    @State private var dragStartHeight: CGFloat?
    /// Set once an outcome has been handed back, so dismissal by any other route can
    /// still preserve what was typed without reporting a second outcome.
    @State private var hasReportedOutcome = false
    @FocusState private var isFocused: Bool
    private let budget: GeminiInputBudget

    /// The legacy dialog opened at 640x220 and could be resized to taste.
    private static let sheetWidth: CGFloat = 620
    private static let defaultEditorHeight: CGFloat = 108
    private static let minimumEditorHeight: CGFloat = 56
    private static let maximumEditorHeight: CGFloat = 520

    init(
        prompt: BrowserModel.InputPrompt,
        validationMessage: String?,
        completion: @escaping (CapsuleInputOutcome) -> Void
    ) {
        self.prompt = prompt
        self.validationMessage = validationMessage
        self.completion = completion
        _value = State(initialValue: prompt.initialText)
        _editorHeight = State(initialValue: Self.defaultEditorHeight)
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

            if prompt.isSensitive {
                // A sensitive prompt stays one line. There is no secure multiline control
                // on the platform, and a password-style answer does not want one.
                SecureField("Response", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { submit() }
            } else {
                responseEditor
            }

            HStack(alignment: .firstTextBaseline) {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Input error: \(validationMessage)")
                } else if !prompt.isSensitive {
                    Text("Return sends. Shift-Return for a line break.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(budgetLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isWithinBudget ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .accessibilityLabel(budgetAccessibilityLabel)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { report(.cancel(draft: value)) }
                    .keyboardShortcut(.cancelAction)
                Button("Submit") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isWithinBudget)
            }
        }
        .padding(24)
        .frame(width: Self.sheetWidth)
        .onAppear { isFocused = true }
        .interactiveDismissDisabled()
        // Dismissal by any route other than the two buttons — navigating away, closing
        // the window — must still keep what was typed. Reporting a cancel here is what
        // files the draft; `cancelInput` ignores it for a sensitive prompt.
        .onDisappear {
            // A sensitive answer is never kept, so there is nothing to report for one.
            guard !hasReportedOutcome, !prompt.isSensitive else { return }
            completion(.dismissed(draft: value))
        }
    }

    private var responseEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $value)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(height: editorHeight)
                .focused($isFocused)
                // Return sends the answer, because that is what a prompt's default
                // action is. A line break therefore needs a modifier, and the text system
                // already binds Shift-Return to one, inserted at the caret. Anything with
                // a modifier is passed straight through to it.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    submit()
                    return .handled
                }
            resizeGrip
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    /// Lets the reader make the field taller.
    ///
    /// A macOS sheet cannot be resized by dragging its edge, and the legacy dialog was a
    /// real resizable window. Dragging this handle changes the field's height and the
    /// sheet grows with it, which is the part that matters when composing a long answer.
    private var resizeGrip: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(nsColor: .tertiaryLabelColor))
            .frame(width: 34, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        let start = dragStartHeight ?? editorHeight
                        dragStartHeight = start
                        editorHeight = min(
                            max(start + gesture.translation.height, Self.minimumEditorHeight),
                            Self.maximumEditorHeight
                        )
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .onHover { isInside in
                if isInside {
                    NSCursor.resizeUpDown.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .accessibilityLabel("Resize the response field")
            .accessibilityAddTraits(.isButton)
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
        report(.submit(value))
    }

    private func report(_ outcome: CapsuleInputOutcome) {
        hasReportedOutcome = true
        completion(outcome)
    }
}

private extension View {
    /// Application-wide command notifications are received by every window's selected
    /// tab. `condition` restricts the action to the window that should own it.
    func onCommand(
        _ name: Notification.Name,
        when condition: @escaping () -> Bool,
        perform action: @escaping () -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in
            guard condition() else { return }
            action()
        }
    }
}

extension Notification.Name {
    static let majorTomAbout = Notification.Name("MajorTomAbout")
    static let majorTomAboutWindowWillClose = Notification.Name("MajorTomAboutWindowWillClose")
    static let majorTomImportData = Notification.Name("MajorTomImportData")
    static let majorTomNewTab = Notification.Name("MajorTomNewTab")
    static let majorTomNewTabAtEnd = Notification.Name("MajorTomNewTabAtEnd")
    static let majorTomCloseTab = Notification.Name("MajorTomCloseTab")
    static let majorTomCloseOtherTabs = Notification.Name("MajorTomCloseOtherTabs")
    static let majorTomCloseWindow = Notification.Name("MajorTomCloseWindow")
    static let majorTomCloseAllWindows = Notification.Name("MajorTomCloseAllWindows")
    static let majorTomFocusLocation = Notification.Name("MajorTomFocusLocation")
    static let majorTomReload = Notification.Name("MajorTomReload")
    static let majorTomStop = Notification.Name("MajorTomStop")
    static let majorTomShowSource = Notification.Name("MajorTomShowSource")
    static let majorTomArchive = Notification.Name("MajorTomArchive")
    static let majorTomAddBookmark = Notification.Name("MajorTomAddBookmark")
    static let majorTomShowBookmarks = Notification.Name("MajorTomShowBookmarks")
    static let majorTomShowClientCertificates = Notification.Name("MajorTomShowClientCertificates")
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
    static let majorTomOpenICloudTab = Notification.Name("MajorTomOpenICloudTab")
}
