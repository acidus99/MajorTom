import AppKit
import MajorTomAppKitSupport
import MajorTomCore
import SwiftUI
import WebKit

/// Both Settings entries target the same window, with independent saved slots.
@MainActor
final class ContentThemePickerSelection: ObservableObject {
    static let shared = ContentThemePickerSelection()
    @Published var slot = ContentThemeAppearance.light
    @Published var themeID: String?

    func prepare(for slot: ContentThemeAppearance) {
        self.slot = slot
        let preferences = ApplicationServices.settings.preferences
        let id = slot == .light ? preferences.lightContentTheme : preferences.darkContentTheme
        let themes = ApplicationServices.themes.themes
        let selected = themes.first { $0.id == id } ?? ContentTheme.fallback(in: themes, for: slot)
        themeID = selected.id.isEmpty ? nil : selected.id
    }
}

struct ContentThemePickerView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var selection = ContentThemePickerSelection.shared
    @ObservedObject private var themes = ApplicationServices.themes
    @ObservedObject private var settings = ApplicationServices.settings
    @State private var creation: ThemeCreation?
    @State private var actionError: String?
    @State private var previewHTML: String?
    @State private var previewError: String?
    @State private var previewAppearance = ContentThemeAppearance.light
    @State private var previewedIdentity: String?
    @State private var expandedFolders: Set<String> = []

    private var selectedTheme: ContentTheme? {
        themes.themes.first { $0.id == selection.themeID }
    }

    private var previewIdentity: String {
        "\(selection.slot.rawValue)\n\(selectedTheme?.css ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(selection: $selection.themeID) {
                    Section("Built-in") {
                        themeSection(isCustom: false)
                    }
                    Section("Custom") {
                        themeSection(isCustom: true)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Content themes")
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)

                VStack(alignment: .leading, spacing: 12) {
                    if let theme = selectedTheme {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(theme.label).font(.title2)
                            Text(theme.metadata["author"].map { "By \($0)" } ?? "Author not specified")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let description = theme.metadata["description"] {
                                Text(description).foregroundStyle(.secondary)
                            }
                            if let source = theme.sourceURL {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Source:").foregroundStyle(.secondary)
                                    Link(source.absoluteString, destination: source)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(source.absoluteString)
                                        .accessibilityLabel("Theme source")
                                        .accessibilityValue(source.absoluteString)
                                }
                                .font(.subheadline)
                            }
                        }
                        .textSelection(.enabled)
                        .padding([.top, .horizontal])

                        if let error = previewError {
                            ContentUnavailableView("Couldn’t Preview Theme", systemImage: "exclamationmark.triangle", description: Text(error))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let previewHTML {
                            ThemePreviewWebView(html: previewHTML, appearance: previewAppearance)
                                .accessibilityLabel("Theme reading preview")
                        } else {
                            ProgressView("Loading Preview…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ContentUnavailableView("Select a Theme", systemImage: "paintpalette")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            if let error = themes.error {
                Text(error)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).help(error)
                    .padding([.top, .horizontal])
            }
            HStack {
                Button("Create Theme…") {
                    creation = ThemeCreation(original: nil, name: "Untitled Theme")
                }
                Button(selectedTheme?.isCustom == true ? "Edit Theme…" : "Customize Theme…") {
                    guard let theme = selectedTheme else { return }
                    if theme.isCustom {
                        do { try themes.openInEditor(theme) }
                        catch { actionError = error.localizedDescription }
                    } else {
                        creation = ThemeCreation(original: theme, name: ContentThemeAuthoring.suggestedCopyName(for: theme))
                    }
                }
                .disabled(selectedTheme == nil)
                Button("Open Themes Folder…") { themes.openCustomThemesInFinder() }
                    .help("Open the custom themes folder in Finder.")
                Spacer()
                Button("Cancel") { dismissWindow(id: "content-themes") }
                    .keyboardShortcut(.cancelAction)
                Button("Use Theme") { useSelectedTheme() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedTheme == nil || previewedIdentity != previewIdentity || previewError != nil)
            }
            .padding()
        }
        .frame(minWidth: 860, minHeight: 620)
        .navigationTitle("Choose \(selection.slot.label) Content Theme")
        .preferredColorScheme(applicationColorScheme)
        .onAppear { revealSelectedTheme() }
        .onChange(of: selection.themeID) { _, _ in revealSelectedTheme() }
        .onChange(of: selectedTheme?.appearance) { _, _ in revealSelectedTheme() }
        .onChange(of: themes.themes) { previous, current in
            guard let id = selection.themeID,
                  previous.contains(where: { $0.id == id }),
                  !current.contains(where: { $0.id == id }) else { return }
            selection.prepare(for: selection.slot)
        }
        .task(id: previewIdentity) { await refreshPreview() }
        .sheet(item: $creation) { request in
            ThemeNameSheet(
                suggestedName: request.name, appearance: selection.slot, showsTemplatePicker: request.original == nil
            ) { name, appearance in
                let theme = try await themes.createTheme(name: name, appearance: appearance, copying: request.original)
                selection.themeID = theme.id
                creation = nil
                do { try themes.openInEditor(theme) }
                catch { actionError = "The theme was created, but couldn’t be opened: \(error.localizedDescription)" }
            }
        }
        .alert("Couldn’t Open Theme", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func themeSection(isCustom: Bool) -> some View {
        let sectionThemes = themes.themes.filter { $0.isCustom == isCustom }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Group {
            themeFolder(.light, themes: sectionThemes, isCustom: isCustom)
            themeFolder(.dark, themes: sectionThemes, isCustom: isCustom)
            ForEach(sectionThemes.filter { $0.appearance == .both }) { theme in
                themeRow(theme)
            }
        }
    }

    private func themeFolder(_ appearance: ContentThemeAppearance, themes: [ContentTheme], isCustom: Bool) -> some View {
        let children = themes.filter { $0.appearance == appearance }
        let id = folderID(for: appearance, isCustom: isCustom)
        return Group {
            if !children.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedFolders.contains(id) },
                    set: { expanded in
                        if expanded { expandedFolders.insert(id) }
                        else { expandedFolders.remove(id) }
                    }
                )) {
                    ForEach(children) { theme in themeRow(theme) }
                } label: {
                    Label(appearance.label, systemImage: "folder")
                }
                .tag(id)
            }
        }
    }

    private func folderID(for appearance: ContentThemeAppearance, isCustom: Bool) -> String {
        "folder:\(isCustom ? "custom" : "built-in"):\(appearance.rawValue)"
    }

    private func revealSelectedTheme() {
        guard let theme = selectedTheme, theme.appearance != .both else { return }
        expandedFolders.insert(folderID(for: theme.appearance, isCustom: theme.isCustom))
    }

    private func themeRow(_ theme: ContentTheme) -> some View {
        Text(theme.name)
            .tag(theme.id)
            .contextMenu {
                Button("Duplicate Theme…") {
                    selection.themeID = theme.id
                    creation = ThemeCreation(original: theme, name: ContentThemeAuthoring.suggestedCopyName(for: theme))
                }
                if theme.isCustom {
                    Button("Edit Theme…") {
                        do { try themes.openInEditor(theme) }
                        catch { actionError = error.localizedDescription }
                    }
                }
            }
    }

    private var applicationColorScheme: ColorScheme? {
        switch settings.preferences.applicationAppearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private func refreshPreview() async {
        previewHTML = nil
        previewError = nil
        previewedIdentity = nil
        guard let theme = selectedTheme else { return }
        let appearance = theme.renderingAppearance(for: selection.slot)
        do {
            let resolved = try await ContentThemeResolver().resolve(theme, appearance: appearance)
            try Task.checkCancellation()
            previewAppearance = appearance
            previewHTML = ContentThemePreviewDocument.render(theme: theme, appearance: appearance, palette: resolved.palette)
            previewedIdentity = previewIdentity
        } catch {
            if !Task.isCancelled { previewError = error.localizedDescription }
        }
    }

    private func useSelectedTheme() {
        guard let theme = selectedTheme else { return }
        if selection.slot == .light { settings.preferences.lightContentTheme = theme.id }
        else { settings.preferences.darkContentTheme = theme.id }
        dismissWindow(id: "content-themes")
    }
}

private struct ThemeCreation: Identifiable {
    let id = UUID()
    let original: ContentTheme?
    let name: String
}

private struct ThemeNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var appearance: ContentThemeAppearance
    @State private var isCreating = false
    @State private var error: String?
    @FocusState private var nameIsFocused: Bool
    let showsTemplatePicker: Bool
    let create: (String, ContentThemeAppearance) async throws -> Void

    init(
        suggestedName: String, appearance: ContentThemeAppearance, showsTemplatePicker: Bool,
        create: @escaping (String, ContentThemeAppearance) async throws -> Void
    ) {
        _name = State(initialValue: suggestedName)
        _appearance = State(initialValue: appearance)
        self.showsTemplatePicker = showsTemplatePicker
        self.create = create
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Custom Theme").font(.headline)
            TextField("Theme name", text: $name).focused($nameIsFocused)
                .disabled(isCreating)
            if showsTemplatePicker {
                Picker("Starting colors", selection: $appearance) {
                    Text("Light").tag(ContentThemeAppearance.light)
                    Text("Dark").tag(ContentThemeAppearance.dark)
                }
                .pickerStyle(.menu)
                .help("Choose the light or dark starting palette for the new theme.")
                .disabled(isCreating)
            }
            Text("The CSS file will open in your default editor. Saved changes update its preview and any tabs already using it.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isCreating)
                Button("Create") {
                    isCreating = true
                    Task {
                        do { try await create(name, appearance) }
                        catch { self.error = error.localizedDescription }
                        isCreating = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { nameIsFocused = true }
        .interactiveDismissDisabled(isCreating)
    }
}

/// Preview WebKit is independent of browser tabs and has no navigation or resource bridge.
private struct ThemePreviewWebView: NSViewRepresentable {
    let html: String
    let appearance: ContentThemeAppearance

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(PreformattedBlockPresentationScript.userScript)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let isDocument = navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank"
            return isDocument ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.querySelectorAll('details')[1]?.removeAttribute('open')", in: nil, in: .defaultClient) { _ in }
        }
    }
}
