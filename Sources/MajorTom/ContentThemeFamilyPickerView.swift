import MajorTomAppKitSupport
import MajorTomCore
import SwiftUI

@MainActor
final class ContentThemeFamilyPickerSelection: ObservableObject {
    static let shared = ContentThemeFamilyPickerSelection()
    @Published var familyID: String?

    func prepare() {
        let families = ApplicationServices.themes.families
        let saved = ApplicationServices.settings.preferences.contentThemeFamily?.id
        familyID = families.first { $0.id == saved }?.id ?? ContentThemeFamily.fallback(in: families)?.id
    }
}

struct ContentThemeFamilyPickerView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var selection = ContentThemeFamilyPickerSelection.shared
    @ObservedObject private var themes = ApplicationServices.themes
    @ObservedObject private var settings = ApplicationServices.settings
    @State private var previewAppearance = ContentThemeAppearance.light
    @State private var lightHTML: String?
    @State private var darkHTML: String?
    @State private var previewError: String?
    @State private var previewedIdentity: String?

    private var selectedFamily: ContentThemeFamily? {
        themes.families.first { $0.id == selection.familyID }
    }
    private var lightTheme: ContentTheme? { themes.themes.first { $0.id == selectedFamily?.lightTheme } }
    private var darkTheme: ContentTheme? { themes.themes.first { $0.id == selectedFamily?.darkTheme } }
    private var previewIdentity: String {
        "\(selection.familyID ?? "")\n\(lightTheme?.css ?? "")\n\(darkTheme?.css ?? "")"
    }

    var body: some View {
        ContentThemePickerLayout {
            List(selection: $selection.familyID) {
                familySection(isCustom: false)
                familySection(isCustom: true)
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Theme families")
        } detail: {
            if let family = selectedFamily {
                VStack(alignment: .leading, spacing: 12) {
                    Text(family.name).font(.title2).padding([.top, .horizontal])
                    TabView(selection: $previewAppearance) {
                        ContentThemePreviewPane(theme: lightTheme, html: lightHTML, error: previewError, appearance: .light)
                            .tabItem { Text("Light") }.tag(ContentThemeAppearance.light)
                        ContentThemePreviewPane(theme: darkTheme, html: darkHTML, error: previewError, appearance: .dark)
                            .tabItem { Text("Dark") }.tag(ContentThemeAppearance.dark)
                    }
                    .padding([.horizontal, .bottom])
                    .accessibilityLabel("Family appearance preview")
                }
            } else {
                ContentUnavailableView("Select a Theme Family", systemImage: "paintpalette",
                    description: Text("A family contains one light theme and one dark theme."))
            }
        } footer: {
            VStack(spacing: 0) {
                if let error = themes.error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).help(error)
                        .padding([.top, .horizontal])
                }
                HStack {
                    Button("Open Themes Folder…") { themes.openCustomThemesInFinder() }
                        .help("Open the custom themes folder in Finder.")
                    Spacer()
                    Button("Cancel") { dismissWindow(id: "content-theme-families") }
                        .keyboardShortcut(.cancelAction)
                    Button("Use Family") { useSelectedFamily() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedFamily == nil || previewedIdentity != previewIdentity || previewError != nil)
                }
                .padding()
            }
        }
        .navigationTitle("Choose Theme Family")
        .preferredColorScheme(applicationColorScheme)
        .task(id: previewIdentity) { await refreshPreviews() }
        .onChange(of: themes.families) { _, current in
            if !current.contains(where: { $0.id == selection.familyID }) { selection.prepare() }
        }
    }

    private func familySection(isCustom: Bool) -> some View {
        let families = themes.families.filter { $0.isCustom == isCustom }
        return Group {
            if !families.isEmpty {
                Section(isCustom ? "Custom" : "Built-in") {
                    ForEach(families) { family in Text(family.name).tag(family.id) }
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

    private func refreshPreviews() async {
        lightHTML = nil
        darkHTML = nil
        previewError = nil
        previewedIdentity = nil
        guard let lightTheme, let darkTheme else { return }
        let identity = previewIdentity
        do {
            let light = try await ContentThemeResolver().resolve(lightTheme, appearance: .light)
            try Task.checkCancellation()
            let dark = try await ContentThemeResolver().resolve(darkTheme, appearance: .dark)
            try Task.checkCancellation()
            lightHTML = ContentThemePreviewDocument.render(theme: lightTheme, appearance: .light, palette: light.palette)
            darkHTML = ContentThemePreviewDocument.render(theme: darkTheme, appearance: .dark, palette: dark.palette)
            previewedIdentity = identity
        } catch {
            if !Task.isCancelled { previewError = error.localizedDescription }
        }
    }

    private func useSelectedFamily() {
        guard let family = selectedFamily else { return }
        var preferences = settings.preferences
        preferences.contentThemeSelection = .family
        preferences.contentThemeFamily = family
        settings.preferences = preferences
        dismissWindow(id: "content-theme-families")
    }
}
