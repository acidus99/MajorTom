import AppKit
import Combine
import Foundation
import MajorTomAppKitSupport
import MajorTomCore

@MainActor
final class ContentThemeStore: ObservableObject {
    @Published private(set) var themes: [ContentTheme] = []
    @Published private(set) var families: [ContentThemeFamily] = []
    @Published private(set) var resolved: ResolvedContentTheme?
    @Published private(set) var error: String?
    let themeDidChange = PassthroughSubject<Void, Never>()

    private let directory: URL?
    private let settings: BrowserSettingsStore
    private var watchers: [any DispatchSourceFileSystemObject] = []
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var catalogGeneration = 0
    private var catalogTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var generation = 0
    private var pendingSelection: (theme: ContentTheme, appearance: ContentThemeAppearance)?
    private var hasLoadedCatalog = false
    private var catalogError: String?

    init(settings: BrowserSettingsStore, directory: URL?) {
        self.settings = settings
        self.directory = directory
        reloadThemes()
        settings.preferencesDidChange
            .sink { [weak self] _ in self?.resolveSelection() }
            .store(in: &cancellables)
        // Application appearance is applied to individual windows; the application's
        // effectiveAppearance continues to represent macOS, independently of that setting.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.resolveSelection() }
        }
    }

    func openCustomThemesInFinder() {
        do {
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(directory) else { throw CocoaError(.fileReadUnknown) }
            reloadThemes()
        } catch { self.error = error.localizedDescription }
    }

    func createTheme(name: String, appearance: ContentThemeAppearance, copying original: ContentTheme?) async throws -> ContentTheme {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let url = try await Task.detached(priority: .utility) {
            try ContentThemeAuthoring.create(in: directory, name: name, appearance: appearance, copying: original)
        }.value
        reloadThemes()
        await waitForCatalog()
        guard let theme = themes.first(where: { $0.id == "custom/" + url.lastPathComponent }) else {
            throw CocoaError(.fileReadUnknown)
        }
        return theme
    }

    func openInEditor(_ theme: ContentTheme) throws {
        guard theme.isCustom, let directory,
              themes.contains(where: { $0.id == theme.id }) else { throw CocoaError(.fileNoSuchFile) }
        let url = directory.appendingPathComponent(String(theme.id.dropFirst("custom/".count)))
        guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
    }

    func waitUntilReady() async {
        await waitForCatalog()
        while resolved == nil, let task = resolutionTask {
            let requestedGeneration = generation
            await task.value
            if generation == requestedGeneration { break }
        }
    }

    private func waitForCatalog() async {
        while let task = catalogTask {
            let requestedGeneration = catalogGeneration
            await task.value
            if requestedGeneration == catalogGeneration { return }
        }
    }

    private func reloadThemes() {
        catalogGeneration += 1
        catalogTask?.cancel()
        let directory = directory
        catalogTask = Task { @MainActor [weak self] in
            let catalog = await Task.detached(priority: .utility) {
                var themes: [ContentTheme] = []
                var errors: [String] = []
                do {
                    let bundled = try ContentTheme.loadBundledThemes(in: ContentTheme.bundledDirectory)
                    themes += bundled.themes
                    errors += bundled.errors
                } catch { errors.append(error.localizedDescription) }
                do {
                    guard let directory else { throw CocoaError(.fileNoSuchFile) }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let custom = try ContentTheme.loadCustomThemes(in: directory)
                    themes += custom.themes
                    errors += custom.errors
                } catch { errors.append(error.localizedDescription) }
                let familyCatalog = ContentThemeFamily.catalog(in: themes)
                errors += familyCatalog.errors
                return (themes: themes, families: familyCatalog.families, errors: errors)
            }.value
            guard let self, !Task.isCancelled else { return }
            hasLoadedCatalog = true
            themes = catalog.themes
            families = catalog.families
            catalogError = catalog.errors.isEmpty ? nil : catalog.errors.joined(separator: "\n")
            error = catalogError
            watchThemes()
            resolveSelection()
        }
    }

    private func watchThemes() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        // Watch files for in-place writes and their directories for replacement/deletion.
        // The custom folder's parent also observes recreation after the folder is removed.
        var urls = [ContentTheme.bundledDirectory]
        if let directory { urls += [directory, directory.deletingLastPathComponent()] }
        for theme in themes {
            let root = theme.isCustom ? directory : ContentTheme.bundledDirectory
            if let root { urls.append(root.appendingPathComponent((theme.id as NSString).lastPathComponent)) }
        }
        for url in urls {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .attrib], queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reloadThemes()
        }
    }

    private func resolveSelection() {
        // Do not reconcile against an initial empty catalog while its files are loading.
        guard hasLoadedCatalog else { return }
        settings.reconcileContentThemes(in: themes)
        let systemIsDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let selection = ContentTheme.selected(
            in: themes, preferences: settings.preferences, systemIsDark: systemIsDark
        )
        if pendingSelection?.theme == selection.theme, pendingSelection?.appearance == selection.appearance { return }
        generation += 1
        let requestedGeneration = generation
        resolutionTask?.cancel()
        pendingSelection = nil
        guard resolved?.theme != selection.theme || resolved?.appearance != selection.appearance else { return }
        pendingSelection = selection
        resolutionTask = Task { @MainActor [weak self] in
            do {
                let result = try await ContentThemeResolver().resolve(selection.theme, appearance: selection.appearance)
                guard let self, !Task.isCancelled, generation == requestedGeneration else { return }
                pendingSelection = nil
                resolved = result
                self.error = catalogError
                themeDidChange.send()
            } catch {
                guard let self, !Task.isCancelled, generation == requestedGeneration else { return }
                pendingSelection = nil
                self.error = "Couldn’t load \(selection.theme.name): \(error.localizedDescription)"
            }
        }
    }
}
