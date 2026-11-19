import AppKit
import AVKit
import MajorTomCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class ImportDataModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case lagrange = "Lagrange"
        case alhena = "Alhena"
        var id: String { rawValue }
    }

    @Published var source: Source = .lagrange
    @Published var step = 0
    @Published var export: ParsedUserDataExport?
    @Published var errorMessage: String?
    @Published var isCheckingArchive = false

    func sourceChanged() {
        export = nil
        errorMessage = nil
    }

    func chooseExport() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(source.rawValue) User Data Export"
        panel.prompt = "Choose Export"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export = nil
        errorMessage = nil
        guard url.lastPathComponent.localizedCaseInsensitiveContains(source.rawValue) else {
            errorMessage = "Choose a \(source.rawValue) User Data Export ZIP file."
            return
        }
        let selectedSource = source
        isCheckingArchive = true
        Task { @MainActor in
            do {
                // A User Data export can contain a large trust database. Reading it on
                // the main actor used to leave the app unable to redraw while unzip was
                // producing output.
                let parsedExport = try await Task.detached(priority: .userInitiated) {
                    switch selectedSource {
                    case .lagrange: ParsedUserDataExport.lagrange(try LagrangeArchiveReader.read(url))
                    case .alhena: ParsedUserDataExport.alhena(try AlhenaArchiveReader.read(url))
                    }
                }.value
                export = parsedExport
            } catch {
                self.export = nil
                errorMessage = error.localizedDescription
            }
            isCheckingArchive = false
        }
    }

    func importExport() {
        guard let export else { return }
        step = 2
        errorMessage = nil
        Task { @MainActor in
            // Give SwiftUI an opportunity to present the progress screen before any
            // import work begins.
            await Task.yield()
            do { try await UserDataImportComposition.importer.importExport(export) }
            catch UserDataImportError.accountChanged {
                errorMessage = "The iCloud account changed. Import stopped; earlier changes were kept."
            } catch {
                errorMessage = "Import could not finish. Earlier changes were kept. Try again."
            }
        }
    }
}

private final class ExportVideoController: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(resourceName: String) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else { return }
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func playFromBeginning() {
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func stop() {
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    deinit { player.pause() }
}

private struct LoopingVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

/// Reads only named files from an archive. No untrusted path is ever extracted to disk.
private struct ImportDataView: View {
    @StateObject private var model = ImportDataModel()
    @ObservedObject private var importer = UserDataImportComposition.importer
    private var isBusy: Bool { model.isCheckingArchive || importer.isImporting }
    @StateObject private var lagrangeVideo = ExportVideoController(resourceName: "lagrange-data-export")
    @StateObject private var alhenaVideo = ExportVideoController(resourceName: "alhena-data-export")
    let dismiss: () -> Void
    let setWindowTitle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch model.step {
                case 0: sourceStep
                case 1: clientStep
                default: progressStep
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if model.step == 1 { Button("Back") { model.step = 0 } }
                Spacer()
                if model.step == 0 {
                    Button("Next") { model.step = 1 }
                        .keyboardShortcut(.defaultAction)
                } else if model.step == 1 {
                    Button("Import") { model.importExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.export == nil || isBusy)
                } else if !isBusy {
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                }
            }
            .frame(height: 52)
        }
        .padding(24)
        // This is hosted directly in an NSPanel rather than presented as a SwiftUI
        // sheet. Keep its fitted size stable as the source changes: on macOS 26,
        // animating an NSHostingView-owned panel during a radio-group update can throw
        // an AppKit constraint exception.
        .frame(width: 650, height: 580, alignment: .topLeading)
        .onAppear { updateWindowTitle() }
        .onChange(of: model.step) { _, _ in updateWindowTitle() }
        .onChange(of: isBusy) { _, _ in updateWindowTitle() }
        .onChange(of: model.source) { _, _ in model.sourceChanged() }
    }

    private func updateWindowTitle() {
        let title = switch model.step {
        case 0: "Import Data from Other Clients"
        case 1: "Import from \(model.source.rawValue)"
        default: isBusy ? "Importing from \(model.source.rawValue)" : "Import Complete"
        }
        setWindowTitle(title)
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bring your bookmarks and preferences with you so Major Tom feels familiar from the start.")
                Text("What gets imported depends on the data included by the selected client.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Import from:")
                    .fontWeight(.medium)
                Picker("Import from", selection: $model.source) {
                    ForEach(ImportDataModel.Source.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("From \(model.source.rawValue), Major Tom can import:")
                    .fontWeight(.medium)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(sourceImportItems.enumerated()), id: \.offset) { _, item in
                        Text("• \(item)")
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var sourceImportItems: [String] {
        switch model.source {
        case .lagrange:
            [
                "Bookmarks",
                "Homepage, when a bookmark is marked as home",
                "Client-side certificates and path assignments",
                "Trusted capsule identities"
            ]
        case .alhena:
            [
                "Bookmarks and homepage, when included",
                "UI appearance, search engine, and HTTP proxy",
                "Client-side certificates and path assignments"
            ]
        }
    }

    private var clientStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            LoopingVideoView(player: model.source == .lagrange ? lagrangeVideo.player : alhenaVideo.player)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Silent looping demonstration of exporting \(model.source.rawValue) user data")
            Text("In \(model.source.rawValue), choose File > User Data > Export. Save the ZIP file, then choose it below.")
                .fixedSize(horizontal: false, vertical: true)
            Text(importDescription)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose UserData Export…") { model.chooseExport() }
                .disabled(isBusy)
            importStatus
        }
        .onAppear { selectedVideo.playFromBeginning() }
        .onDisappear { selectedVideo.stop() }
    }

    private var selectedVideo: ExportVideoController {
        model.source == .lagrange ? lagrangeVideo : alhenaVideo
    }

    private var importDescription: String {
        switch model.source {
        case .lagrange:
            "Imports bookmarks, homepage, client certificates, identity assignments, and trusted capsule identities. Existing data is kept."
        case .alhena:
            "Imports bookmarks, homepage, client certificates, identity assignments, appearance, HTTP proxy, and search settings. Existing data is kept."
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isBusy && model.export == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(model.source.rawValue) export…").foregroundStyle(.secondary)
                }
            }
            if let export = model.export {
                Label {
                    Text("Valid \(model.source.rawValue) export detected (version \(export.version)).")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .font(.body)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .topLeading)
    }

    private var progressStep: some View {
        Group {
            if isBusy {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Importing data from \(model.source.rawValue)…")
                        .font(.title2)
                    if let progress = importer.importProgress {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        Text(progress.message)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Preparing import…")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 72)
            } else if let error = model.errorMessage {
                ContentUnavailableView("Import Stopped", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                VStack(alignment: .center, spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Import complete")
                    Text("Your data was imported from \(model.source.rawValue).")
                        .font(.title2)
                    if let items = importer.resultItems, !items.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                Text("• \(item)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                    } else {
                        Text("No new data was added.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Existing data was kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

@MainActor
enum ImportDataWindowPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 580),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Import Data from Other Clients"
        let contentSize = NSSize(width: 650, height: 580)
        panel.contentMinSize = contentSize
        panel.contentMaxSize = contentSize
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: ImportDataView(
            dismiss: { panel.close() },
            setWindowTitle: { panel.title = $0 }
        ))
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
