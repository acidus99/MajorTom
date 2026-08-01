import AppKit
import Combine
import MajorTomCore
import SwiftUI

@main
struct MajorTomApp: App {
    @NSApplicationDelegateAdaptor(MajorTomApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            NativeFoundationView()
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

                Divider()

                Button("Open Location…") {
                    NotificationCenter.default.post(name: .majorTomFocusLocation, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Save Page As…") {
                    NotificationCenter.default.post(name: .majorTomSavePage, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
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
                Button("Up One Level") { NotificationCenter.default.post(name: .majorTomUp, object: nil) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Capsule Root") { NotificationCenter.default.post(name: .majorTomRoot, object: nil) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            }
        }

        Settings {
            BrowserSettingsView()
        }
    }
}

private final class MajorTomApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate()
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

private struct NativeFoundationView: View {
    @ObservedObject private var settings = BrowserSettingsStore.shared

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                BrowserWindowView()
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
    @StateObject private var session = BrowserWindowSession()
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            BrowserTabStrip(session: session)
            if let selectedTab = session.selectedTab {
                BrowserTabView(browser: selectedTab.browser)
                    .id(selectedTab.id)
            }
        }
        .navigationTitle(session.selectedTab?.browser.title ?? "Major Tom")
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
    }
}

@available(macOS 26.0, *)
@MainActor
private final class BrowserWindowSession: ObservableObject {
    @MainActor
    final class Tab: Identifiable {
        let id = UUID()
        let browser: BrowserModel

        init(restoredState: RestoredTabState? = nil) {
            browser = BrowserModel(restoredState: restoredState)
        }
    }

    @Published private(set) var tabs: [Tab]
    @Published var selectedID: UUID? {
        didSet { scheduleSave() }
    }
    private var observers: [UUID: AnyCancellable] = [:]

    init() {
        if let restored = SessionRestorationStore.shared.load(), !restored.tabs.isEmpty {
            tabs = restored.tabs.map { Tab(restoredState: $0) }
            selectedID = tabs.indices.contains(restored.selectedIndex)
                ? tabs[restored.selectedIndex].id
                : tabs.first?.id
        } else {
            tabs = [Tab()]
            selectedID = tabs.first?.id
        }
        for tab in tabs { observe(tab) }
    }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedID } ?? tabs.first
    }

    func newTab() {
        let tab = Tab()
        tabs.append(tab)
        observe(tab)
        selectedID = tab.id
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
private struct BrowserTabStrip: View {
    @ObservedObject var session: BrowserWindowSession

    var body: some View {
        HStack(spacing: 6) {
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
            }
            Spacer(minLength: 0)
            Button("New Tab", systemImage: "plus") { session.newTab() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .help("New Tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(.bar)
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
        HStack(spacing: 7) {
            if isHovered {
                Button("Close Tab", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Close \(browser.title)")
            }
            if browser.isLoading { ProgressView().controlSize(.mini) }
            Text(browser.title)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 150, maxWidth: 240, minHeight: 30)
        .background(tabBackground, in: Capsule())
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tabBackground: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        }
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.58))
    }
}

@available(macOS 26.0, *)
private struct BrowserTabView: View {
    @ObservedObject var browser: BrowserModel
    @FocusState private var locationIsFocused: Bool
    @FocusState private var findIsFocused: Bool
    @State private var showsFind = false
    @State private var findQuery = ""
    @State private var navigationKeyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left") {
                    browser.goBack()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
                .disabled(!browser.canGoBack)
                .help("Back")

                Button("Forward", systemImage: "chevron.right") {
                    browser.goForward()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
                .disabled(!browser.canGoForward)
                .help("Forward")

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
            .background(.regularMaterial)

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

            if showsFind {
                HStack {
                    TextField("Find on Page", text: $findQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($findIsFocused)
                        .onSubmit { browser.find(findQuery) }
                    Button("Previous", systemImage: "chevron.up") { browser.find(findQuery, backwards: true) }
                        .labelStyle(.iconOnly)
                    Button("Next", systemImage: "chevron.down") { browser.find(findQuery) }
                        .labelStyle(.iconOnly)
                    Button("Done") { showsFind = false }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            StreamingWebViewPrototype(browser: browser)
                .overlay(alignment: .bottomLeading) {
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
        .task { browser.start() }
        .onAppear { installNavigationKeyMonitor() }
        .onDisappear { removeNavigationKeyMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomFocusLocation)) { _ in
            locationIsFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomReload)) { _ in
            browser.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomStop)) { _ in
            browser.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomShowSource)) { _ in
            browser.showPageSource()
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomSavePage)) { _ in
            Task { await browser.savePage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomFind)) { _ in
            showsFind = true
            findIsFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomZoomIn)) { _ in browser.zoomIn() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomZoomOut)) { _ in browser.zoomOut() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomActualSize)) { _ in browser.actualSize() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomBack)) { _ in browser.goBack() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomForward)) { _ in browser.goForward() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomHome)) { _ in browser.goHome() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomUp)) { _ in browser.goUpOneLevel() }
        .onReceive(NotificationCenter.default.publisher(for: .majorTomRoot)) { _ in browser.goToCapsuleRoot() }
        .sheet(item: $browser.trustPrompt) { prompt in
            TrustPromptView(prompt: prompt) { approved in
                browser.respondToTrust(allow: approved)
            }
        }
        .sheet(item: $browser.inputPrompt) { prompt in
            CapsuleInputView(prompt: prompt, validationMessage: browser.inputValidationMessage) { value in
                if let value { browser.submitInput(value) }
                else { browser.cancelInput() }
            }
        }
    }

    private func installNavigationKeyMonitor() {
        removeNavigationKeyMonitor()
        navigationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "[":
                browser.goBack()
                return nil
            case "]":
                browser.goForward()
                return nil
            default:
                return event
            }
        }
    }

    private func removeNavigationKeyMonitor() {
        if let navigationKeyMonitor {
            NSEvent.removeMonitor(navigationKeyMonitor)
            self.navigationKeyMonitor = nil
        }
    }
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
private struct CapsuleInputView: View {
    let prompt: BrowserModel.InputPrompt
    let validationMessage: String?
    let completion: (String?) -> Void
    @State private var value = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.message)
                .font(.headline)
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
            .onSubmit { completion(value) }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Input error: \(validationMessage)")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { completion(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Submit") { completion(value) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { isFocused = true }
        .interactiveDismissDisabled()
    }
}

private extension Notification.Name {
    static let majorTomNewTab = Notification.Name("MajorTomNewTab")
    static let majorTomCloseTab = Notification.Name("MajorTomCloseTab")
    static let majorTomFocusLocation = Notification.Name("MajorTomFocusLocation")
    static let majorTomReload = Notification.Name("MajorTomReload")
    static let majorTomStop = Notification.Name("MajorTomStop")
    static let majorTomShowSource = Notification.Name("MajorTomShowSource")
    static let majorTomSavePage = Notification.Name("MajorTomSavePage")
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
