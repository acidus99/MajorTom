import AppKit
import MajorTomAppKitSupport
import MajorTomCore
import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject private var store = BrowserSettingsStore.shared
    @ObservedObject private var cloud = ICloudSyncStore.shared
    @ObservedObject private var themes = ContentThemeStore.shared
    @State private var isDefaultGeminiBrowser = false
    @State private var defaultBrowserError: String?

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
            Section("Default Gemini browser") {
                Button("Make Major Tom the Default Gemini Browser") {
                    makeMajorTomDefault()
                }
                .disabled(isDefaultGeminiBrowser)

                if isDefaultGeminiBrowser {
                    Label("Major Tom is the default Gemini browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Section("iCloud Syncing") {
                LabeledContent("CloudKit Data") {
                    Label(cloud.status.label, systemImage: "icloud")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(width: 360, alignment: .trailing)
                        .frame(minHeight: 34)
                }
                HStack {
                    Button("Sync Now") {
                        NativeTabCoordinator.shared.publishCloudTabsIfNeeded()
                        cloud.refresh()
                    }
                    if cloud.status == .removed {
                        Button("Re-upload This Mac’s Data…") {
                            Task { await cloud.reuploadAfterCloudDataRemoval() }
                        }
                    }
                }
                Text("iCloud is used to keep the following data in sync: bookmarks, homepage, search provider, Client certificates and their approved capsules and paths, and All Quality of Life settings. A list of the current open windows and tabs can be viewed from other computers via Major Tom's iCloud Tabs feature.")
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
        .onAppear { refreshDefaultBrowserStatus() }
        .alert("Couldn’t Set Default Gemini Browser", isPresented: defaultBrowserErrorPresented) {
            Button("OK", role: .cancel) { defaultBrowserError = nil }
        } message: {
            Text(defaultBrowserError ?? "Launch Services could not update the default application.")
        }
    }

    private var defaultBrowserErrorPresented: Binding<Bool> {
        Binding(
            get: { defaultBrowserError != nil },
            set: { if !$0 { defaultBrowserError = nil } }
        )
    }

    private func refreshDefaultBrowserStatus() {
        isDefaultGeminiBrowser = GeminiDefaultApplication.isMajorTomDefault
    }

    private func makeMajorTomDefault() {
        GeminiDefaultApplication.makeMajorTomDefault { error in
            Task { @MainActor in
                if let error {
                    defaultBrowserError = error.localizedDescription
                } else {
                    refreshDefaultBrowserStatus()
                }
            }
        }
    }

    private var appearance: some View {
        Form {
            Picker("Application appearance", selection: store.binding(\.applicationAppearance)) {
                Text("System").tag(ApplicationAppearance.system)
                Text("Light").tag(ApplicationAppearance.light)
                Text("Dark").tag(ApplicationAppearance.dark)
            }
            Picker("Content appearance", selection: store.binding(\.contentAppearance)) {
                Text("System").tag(ContentAppearance.system)
                Text("Light").tag(ContentAppearance.light)
                Text("Dark").tag(ContentAppearance.dark)
            }
            .help("Choose whether content uses the light theme, the dark theme, or follows macOS appearance.")
            contentThemePicker("Light content theme", appearance: .light, selection: \.lightContentTheme)
            contentThemePicker("Dark content theme", appearance: .dark, selection: \.darkContentTheme)
            Button("Open Custom Themes in Finder") { themes.openCustomThemesInFinder() }
                .help("Open the folder for custom CSS themes. Saved changes apply automatically.")
            if let error = themes.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(error)
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

    private func contentThemePicker(
        _ title: String, appearance: ContentThemeAppearance,
        selection: WritableKeyPath<BrowserPreferences, String>
    ) -> some View {
        let available = themes.themes.filter { $0.appearance.supports(appearance) }
        let selected = store.preferences[keyPath: selection]
        return Picker(title, selection: store.binding(selection)) {
            ForEach(available) { theme in
                Text(theme.label).tag(theme.id)
            }
            if !available.contains(where: { $0.id == selected }) {
                Text("Unavailable Theme (Using Dracula \(appearance.label))").tag(selected)
            }
        }
        .help("Select the theme for \(appearance.label.lowercased()) content. Each name shows its supported appearances.")
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
                ), format: .number.grouping(.never))
            }
            Text("A Gemini proxy converts web pages to Gemtext so web links open inside Major Tom.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var qualityOfLife: some View {
        Form {
            Toggle("Show capsule favicons", isOn: store.binding(\.showsFavicons))
            Text("A capsule may publish one emoji at /favicon.txt. Major Tom shows it on the Page Information button and on the tab, asks for it only after you visit the capsule, and remembers the answer for 30 days.")
                .font(.callout)
                .foregroundStyle(.secondary)


            Toggle("Automatically display same-capsule images", isOn: store.binding(\.automaticallyLoadsSameCapsuleImages))
            Stepper(value: store.binding(\.imageRequestInterval), in: 1...60, step: 1) {
                Text("Image Request Interval: \(Duration.seconds(store.preferences.imageRequestInterval).formatted(.units(allowed: [.seconds], width: .wide)))")
            }
            .help("Minimum time between inline image requests to a capsule. Cached images appear immediately.")
            Text("Cached images appear immediately. Other images wait for this interval, including when a page first opens. Capsules that ask Major Tom to slow down are given progressively longer pauses.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
                "Render ANSI colors in preformatted text",
                isOn: store.binding(\.renderingOptions.rendersANSIColors)
            )
            Toggle(
                "Include ANSI background colors",
                isOn: store.binding(\.renderingOptions.rendersANSIBackgroundColors)
            )
            .disabled(!store.preferences.renderingOptions.rendersANSIColors)
            Text("Some capsules color their ASCII art with terminal escape codes. Major Tom brightens or darkens each color so it stays readable on your content theme. Background colors are applied only where the capsule also sets a text color, because a background on its own can hide the text underneath it.")
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
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var browsingData = BrowsingDataController.shared
    private let store = SharedTrustedIdentityStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Text("Browsing Data")
                .font(.headline)
            Text("Browsing history, cached content, input drafts, and restored tabs are stored only on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Clear Browsing Data…", role: .destructive) {
                    browsingData.action = .clearBrowsingData
                    openWindow(id: "browsing-data")
                }
                .help("Clear history, Back/Forward visits, input drafts, and cached content across all windows.")
                Button("Empty Caches…", role: .destructive) {
                    browsingData.action = .emptyCaches
                    openWindow(id: "browsing-data")
                }
                .help("Discard cached content while keeping history, tabs, and reading positions.")
            }
            .disabled(browsingData.isClearing)
        }
        .task { await reload() }
    }

    @MainActor
    private func reload() async {
        identities = await store?.allIdentities() ?? []
    }
}
