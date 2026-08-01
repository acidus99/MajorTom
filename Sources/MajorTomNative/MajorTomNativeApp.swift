import AppKit
import MajorTomCore
import SwiftUI

@main
struct MajorTomNativeApp: App {
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
            }
        }

        Settings {
            Form {
                Section("General") {
                    LabeledContent("Homepage", value: "gemini://gemi.dev/")
                    LabeledContent("Search provider", value: "Kennedy")
                }
                Section("Privacy & Security") {
                    Text("Capsule identities are trusted on first use and stored in Application Support.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 520, height: 260)
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
    var body: some View {
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
        .navigationTitle(session.selectedTab?.browser.committedURL?.host ?? "Major Tom")
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
        let browser = BrowserModel()
    }

    @Published private(set) var tabs: [Tab] = [Tab()]
    @Published var selectedID: UUID?

    init() {
        selectedID = tabs.first?.id
    }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedID } ?? tabs.first
    }

    func newTab() {
        let tab = Tab()
        tabs.append(tab)
        selectedID = tab.id
    }

    @discardableResult
    func closeSelectedTab() -> Bool {
        guard let selectedID,
              let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return false }
        tabs[index].browser.stop()
        tabs.remove(at: index)
        guard !tabs.isEmpty else { return true }
        self.selectedID = tabs[min(index, tabs.count - 1)].id
        return false
    }
}

@available(macOS 26.0, *)
private struct BrowserTabStrip: View {
    @ObservedObject var session: BrowserWindowSession

    var body: some View {
        HStack(spacing: 1) {
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
        .frame(height: 34)
        .background(.bar)
    }
}

@available(macOS 26.0, *)
private struct BrowserTabButton: View {
    @ObservedObject var browser: BrowserModel
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if browser.isLoading { ProgressView().controlSize(.mini) }
            Text(browser.committedURL?.host ?? "New Tab")
                .lineLimit(1)
            Button("Close Tab", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 150, maxWidth: 240, minHeight: 28)
        .background(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@available(macOS 26.0, *)
private struct BrowserTabView: View {
    @ObservedObject var browser: BrowserModel
    @FocusState private var locationIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left") {
                    browser.goBack()
                }
                .labelStyle(.iconOnly)
                .disabled(!browser.canGoBack)
                .help("Back")

                Button("Forward", systemImage: "chevron.right") {
                    browser.goForward()
                }
                .labelStyle(.iconOnly)
                .disabled(!browser.canGoForward)
                .help("Forward")

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
                    .help("Stop Loading")
                } else {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        browser.reload()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(browser.committedURL == nil)
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
        .sheet(item: $browser.trustPrompt) { prompt in
            TrustPromptView(prompt: prompt) { approved in
                browser.respondToTrust(allow: approved)
            }
        }
        .sheet(item: $browser.inputPrompt) { prompt in
            CapsuleInputView(prompt: prompt) { value in
                if let value { browser.submitInput(value) }
                else { browser.cancelInput() }
            }
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
                    TextField("Response", text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { completion(value) }
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
}
