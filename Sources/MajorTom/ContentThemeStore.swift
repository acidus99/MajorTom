import AppKit
import Combine
import Foundation
import MajorTomAppKitSupport
import MajorTomCore

@MainActor
final class ContentThemeStore: ObservableObject {
    @Published private(set) var themes = ContentTheme.bundled
    @Published private(set) var resolved: ResolvedContentTheme?
    @Published private(set) var error: String?
    let themeDidChange = PassthroughSubject<Void, Never>()

    private let directory: URL?
    private let settings: BrowserSettingsStore
    private var watchers: [any DispatchSourceFileSystemObject] = []
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var refreshTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var generation = 0
    private var pendingSelection: (theme: ContentTheme, appearance: ContentThemeAppearance)?
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

    func waitUntilReady() async {
        while resolved == nil, let task = resolutionTask {
            let requestedGeneration = generation
            await task.value
            if generation == requestedGeneration { break }
        }
    }

    private func reloadThemes() {
        do {
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let custom = try ContentTheme.loadCustomThemes(in: directory)
            themes = ContentTheme.bundled + custom.themes
            catalogError = custom.errors.isEmpty ? nil : custom.errors.joined(separator: "\n")
            error = catalogError
            watch(directory)
        } catch {
            catalogError = error.localizedDescription
            self.error = catalogError
        }
        resolveSelection()
    }

    private func watch(_ directory: URL) {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        // Watch individual files as well as the directory: editors may modify in place
        // or replace a file atomically. Reinstall watches after either kind of save.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in [directory] + files.filter({ $0.pathExtension.lowercased() == "css" }) {
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
