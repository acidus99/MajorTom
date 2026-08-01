import MajorTomCore
import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject private var store = BrowserSettingsStore.shared

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
                Text("Automatic").tag(ContentTheme.automatic)
                Text("Dracula Light").tag(ContentTheme.draculaLight)
                Text("Dracula Dark").tag(ContentTheme.draculaDark)
            }
            Text("Application chrome and document themes are independent.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var networking: some View {
        Form {
            Toggle("Use HTTP CONNECT proxy", isOn: proxyEnabled)
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
            Text("Connections require TLS 1.2 or newer and time out after 30 seconds without activity.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var qualityOfLife: some View {
        Form {
            Toggle("Automatically display same-capsule images", isOn: store.binding(\.automaticallyLoadsSameCapsuleImages))
            Toggle("Display inline data images", isOn: store.binding(\.automaticallyLoadsDataImages))
            Toggle("Recognize *emphasis*", isOn: store.binding(\.renderingOptions.recognizesEmphasis))
            Toggle("Recognize **strong emphasis**", isOn: store.binding(\.renderingOptions.recognizesStrongEmphasis))
            Toggle("Recognize `inline code`", isOn: store.binding(\.renderingOptions.recognizesInlineCode))
        }
        .formStyle(.grouped)
    }

    private var proxyEnabled: Binding<Bool> {
        Binding(
            get: { store.preferences.proxy != nil },
            set: { enabled in
                var updated = store.preferences
                updated.proxy = enabled ? GeminiProxyConfiguration(host: "localhost", port: 8080) : nil
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
    private let store = Self.makeStore()

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

    private static func makeStore() -> TrustedIdentityStore? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return try? TrustedIdentityStore(fileURL: root
            .appendingPathComponent("Major Tom", isDirectory: true)
            .appendingPathComponent("trusted-identities.json"))
    }
}
