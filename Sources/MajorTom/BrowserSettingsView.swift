import AppKit
import MajorTomCore
import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject private var store = BrowserSettingsStore.shared
    @ObservedObject private var cloud = ICloudSyncStore.shared
    @State private var faviconCacheCleared = false

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            appearance
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            networking
                .tabItem { Label("Networking", systemImage: "network") }
            qualityOfLife
                .tabItem { Label("Quality of Life", systemImage: "wand.and.stars") }
            TrustedIdentitiesSettingsView()
                .tabItem { Label("Privacy & Security", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(width: 650, height: 430)
    }

    private var general: some View {
        Form {
            TextField("Homepage", text: store.binding(\.homepage))
            Picker("Search provider", selection: store.binding(\.searchProvider)) {
                Text("Kennedy").tag(SearchProvider.kennedy)
                Text("TLGS").tag(SearchProvider.tlgs)
                Text("Custom").tag(SearchProvider.custom)
            }
            if store.preferences.searchProvider == .custom {
                TextField("Custom search endpoint", text: store.binding(\.customSearchEndpoint))
            }
            Section("iCloud") {
                LabeledContent("Synced data") {
                    Label(cloud.status.label, systemImage: "icloud")
                        .foregroundStyle(.secondary)
                }
                Text("Bookmarks, reading preferences, certificate approvals, trusted capsule keys, and open-tab titles and URLs sync privately through iCloud. Proxy settings, appearance, window layout, history, and restored sessions stay on this Mac. Private keys use iCloud Keychain, not CloudKit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Restore Default Settings", role: .destructive) {
                        store.restoreDefaultSettings()
                    }
                    Button("Delete User Data", role: .destructive) {
                        confirmDeleteUserData()
                    }
                }
                Text("Restores browser settings only. Trusted capsule identities and client certificates are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Picker("Application appearance", selection: store.binding(\.applicationAppearance)) {
                Text("System").tag(ApplicationAppearance.system)
                Text("Light").tag(ApplicationAppearance.light)
                Text("Dark").tag(ApplicationAppearance.dark)
            }
            Picker("Content theme", selection: store.binding(\.contentTheme)) {
                Text("Dracula Light").tag(ContentTheme.draculaLight)
                Text("Dracula Dark").tag(ContentTheme.draculaDark)
                Text("Dracula Classic").tag(ContentTheme.draculaClassic)
                Text("Ocean").tag(ContentTheme.ocean)
                Text("Forest").tag(ContentTheme.forest)
                Text("Creamsicle").tag(ContentTheme.creamsicle)
                Text("Sand Dunes").tag(ContentTheme.sandDunes)
            }
            Picker("Content width", selection: store.binding(\.contentWidth)) {
                Text("Narrow").tag(ContentWidth.narrow)
                Text("Wide").tag(ContentWidth.wide)
                Text("Full").tag(ContentWidth.full)
            }
            Text("Application chrome and document themes are independent.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var networking: some View {
        Form {
            Toggle("Open web links through a Gemini proxy", isOn: proxyEnabled)
            if let proxy = store.preferences.proxy {
                TextField("Proxy host", text: Binding(
                    get: { proxy.host },
                    set: { updateProxy(host: $0) }
                ))
                TextField("Proxy port", value: Binding(
                    get: { Int(proxy.port) },
                    set: { updateProxy(port: UInt16(clamping: $0)) }
                ), format: .number)
            }
            Text("""
            With a proxy set, http:// and https:// links open inside Major Tom: it connects \
            to the proxy over Gemini and sends the web address as the request, and the proxy \
            returns the page converted to Gemtext. Without one, web links open in your \
            default browser.

            Trust is pinned to the proxy's certificate, not the website's — the proxy sees \
            and rewrites everything it fetches for you.

            Connections require TLS 1.2 or newer and time out after 30 seconds without activity.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var qualityOfLife: some View {
        Form {
            Toggle("Show capsule favicons", isOn: store.binding(\.showsFavicons))
            Text("A capsule may publish one emoji at /favicon.txt. Major Tom shows it on the Page Information button and on the tab, asks for it only after you visit the capsule, and remembers the answer for a week.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Clear Favicon Cache") { clearFaviconCache() }
                if faviconCacheCleared {
                    Text("Cleared")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Toggle("Automatically display same-capsule images", isOn: store.binding(\.automaticallyLoadsSameCapsuleImages))
            Toggle("Display inline data images", isOn: store.binding(\.automaticallyLoadsDataImages))
            Toggle(
                "Italicize text between *single asterisks*",
                isOn: store.binding(\.renderingOptions.recognizesEmphasis)
            )
            Toggle(
                "Bold text between **double asterisks**",
                isOn: store.binding(\.renderingOptions.recognizesStrongEmphasis)
            )
            Toggle(
                "Monospace text between `backtick characters`",
                isOn: store.binding(\.renderingOptions.recognizesInlineCode)
            )
            Text("The asterisks and backticks stay visible. Major Tom only adds styling; it never removes characters the author typed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(
                "Collapse consecutive quote lines",
                isOn: store.binding(\.renderingOptions.collapsesConsecutiveQuotes)
            )
            Text("Renders a run of quote lines as one continuous quotation instead of separate blocks.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(
                "Show link type hints",
                isOn: store.binding(\.renderingOptions.showsLinkHints)
            )
            Text("Marks each link with where it leads: \u{2192} elsewhere in this capsule, \u{21D2} to another capsule, \u{1F310} out to the web, \u{1F5BC}\u{FE0F} an image, \u{1F4E7} an email address.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func clearFaviconCache() {
        Task {
            try? await SharedFaviconStore.shared?.removeAll()
            faviconCacheCleared = true
            // Transient confirmation: this is an action, not a state to stay latched on.
            try? await Task.sleep(for: .seconds(2))
            faviconCacheCleared = false
        }
    }

    private func confirmDeleteUserData() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete User Data?"
        alert.informativeText = "This permanently deletes bookmarks, the homepage, client certificates and their capsule assignments, and trusted capsule identities. This action can’t be undone."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let delete = alert.addButton(withTitle: "Delete User Data")
        delete.hasDestructiveAction = true

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            // NSAlert assigns 1_000 to its first button and increments for each
            // following button. Cancel is deliberately first/default; deletion needs
            // an explicit activation of the second button.
            guard response.rawValue == 1_001 else { return }
            Task { @MainActor in
                await deleteUserData()
            }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    private func deleteUserData() async {
        do {
            try await ClientCertificateStore.shared.deleteAll()
            try await BookmarksModel.shared.deleteAll()
            try await SharedTrustedIdentityStore.shared?.removeAllUserTrust()
            var preferences = store.preferences
            preferences.homepage = BrowserPreferences().homepage
            store.preferences = preferences
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private var proxyEnabled: Binding<Bool> {
        Binding(
            get: { store.preferences.proxy != nil },
            set: { enabled in
                var updated = store.preferences
                // 1994 is Stargate's default listening port; 8080 was a leftover from
                // when this setting meant an HTTP CONNECT proxy.
                updated.proxy = enabled ? GeminiProxyConfiguration(host: "localhost", port: 1_994) : nil
                store.preferences = updated
            }
        )
    }

    private func updateProxy(host: String? = nil, port: UInt16? = nil) {
        guard var proxy = store.preferences.proxy else { return }
        if let host { proxy.host = host }
        if let port { proxy.port = port }
        var updated = store.preferences
        updated.proxy = proxy
        store.preferences = updated
    }
}

private struct TrustedIdentitiesSettingsView: View {
    @State private var identities: [TrustedServerIdentity] = []
    @State private var showsClearConfirmation = false
    @ObservedObject private var cloudTrust = TrustedIdentityCloudCoordinator.shared
    private let store = SharedTrustedIdentityStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !cloudTrust.conflictingEndpoints.isEmpty {
                Label(
                    "iCloud has conflicting trusted keys for \(cloudTrust.conflictingEndpoints.count) capsule\(cloudTrust.conflictingEndpoints.count == 1 ? "" : "s"). Major Tom will keep this Mac’s existing decision and will not import a different key unless you approve it.",
                    systemImage: "exclamationmark.shield"
                )
                .foregroundStyle(.orange)
            }
            if identities.isEmpty {
                ContentUnavailableView(
                    "No Trusted Capsules",
                    systemImage: "lock.shield",
                    description: Text("Capsule identities appear here after their first connection.")
                )
            } else {
                List(identities, id: \.endpoint) { identity in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(identity.endpoint.host):\(identity.endpoint.port)")
                            Text(identity.publicKeySHA256)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Remove Trust", role: .destructive) {
                            Task {
                                try? await store?.removeTrust(for: identity.endpoint)
                                await reload()
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Browsing history and restored tabs are stored only on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Browsing Data…", role: .destructive) {
                    showsClearConfirmation = true
                }
            }
        }
        .task { await reload() }
        .confirmationDialog("Clear Browsing Data?", isPresented: $showsClearConfirmation) {
            Button("Clear History and Session", role: .destructive) {
                BrowsingHistoryStore.shared.clear()
                SessionRestorationStore.shared.clear()
            }
        } message: {
            Text("This clears browsing history and prevents the current tabs from being restored after the next launch. Trusted capsule identities and settings are kept.")
        }
    }

    @MainActor
    private func reload() async {
        identities = await store?.allIdentities() ?? []
    }
}
