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
    @Published var export: LagrangeUserDataExport?
    @Published var selectedFileName: String?
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var resultMessage: String?
    @Published var importProgress: (completed: Int, total: Int, message: String)?

    func chooseExport() {
        let panel = NSOpenPanel()
        panel.title = "Choose Lagrange User Data Export"
        panel.prompt = "Choose Export"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent.localizedCaseInsensitiveContains("lagrange") else {
            errorMessage = "Choose a Lagrange User Data Export ZIP file."
            return
        }
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            do {
                // A User Data export can contain a large trust database. Reading it on
                // the main actor used to leave the app unable to redraw while unzip was
                // producing output.
                let parsedExport = try await Task.detached(priority: .userInitiated) {
                    try LagrangeArchiveReader.read(url)
                }.value
                export = parsedExport
                selectedFileName = url.lastPathComponent
            } catch {
                self.export = nil
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    func importExport() {
        guard let export else { return }
        isImporting = true
        errorMessage = nil
        resultMessage = nil
        Task { @MainActor in
            var importedCertificates = 0
            var associations = 0
            var certificatesByDigest: [String: UUID] = [:]
            let totalSteps = max(1, export.identities.count + export.identityAssignments.count + 2)
            var completedSteps = 0
            @MainActor func reportProgress(_ message: String) {
                importProgress = (completedSteps, totalSteps, message)
            }

            reportProgress("Importing client certificates…")
            for (index, identity) in export.identities.enumerated() {
                reportProgress("Importing client certificate \(index + 1) of \(export.identities.count)…")
                defer { completedSteps += 1 }
                do {
                    let parsed = try ClientCertificateImport.parse(
                        pem: identity.certificatePEM + "\n" + identity.privateKeyPEM
                    )
                    let digest = CertificateDetails.sha256(certificateDER: parsed.certificateDER)
                    let isAlreadyImported = ClientCertificateStore.shared.certificates.contains {
                        $0.certificateSHA256 == digest
                    }
                    let descriptor = try await ClientCertificateStore.shared.importIdentity(parsed)
                    certificatesByDigest[identity.digest] = descriptor.id
                    certificatesByDigest[digest] = descriptor.id
                    if !isAlreadyImported { importedCertificates += 1 }
                } catch {
                    // One malformed or unsupported identity must not discard the rest
                    // of an otherwise valid export.
                    continue
                }
            }
            for (index, assignment) in export.identityAssignments.enumerated() {
                reportProgress("Importing identity assignment \(index + 1) of \(export.identityAssignments.count)…")
                defer { completedSteps += 1 }
                guard let certificateID = certificatesByDigest[assignment.identityDigest] else { continue }
                guard let proposed = ClientCertificateAssociation.pathAndDescendants(
                    certificateID: certificateID,
                    url: assignment.url
                ), !ClientCertificateStore.shared.associations.contains(where: {
                    $0.endpoint == proposed.endpoint
                        && $0.scope == proposed.scope
                        && $0.pathPrefix == proposed.pathPrefix
                }) else { continue }
                ClientCertificateStore.shared.associate(
                    certificateID: certificateID,
                    with: assignment.url,
                    scope: .pathAndDescendants
                )
                associations += 1
            }
            reportProgress("Saving trusted capsule identities…")
            let trustedIdentities = export.trustedIdentities.map {
                PresentedServerIdentity(endpoint: $0.endpoint, publicKeySHA256: $0.publicKeySHA256)
            }
            _ = try? await SharedTrustedIdentityStore.shared?.importTrustedIdentities(trustedIdentities)
            completedSteps += 1
            reportProgress("Importing bookmarks and settings…")
            BookmarksModel.shared.importLagrangeBookmarks(export.bookmarks)
            if let homepage = export.bookmarks.first(where: \.isHomepage) {
                var preferences = BrowserSettingsStore.shared.preferences
                preferences.homepage = homepage.url.absoluteString
                BrowserSettingsStore.shared.preferences = preferences
            }
            completedSteps += 1
            isImporting = false
            importProgress = nil
            resultMessage = "Imported \(export.bookmarks.count) bookmarks, \(importedCertificates) client certificates, and \(associations) identity assignments. Existing data was kept."
        }
    }
}

private final class LagrangeExportVideoController: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init() {
        guard let url = Bundle.main.url(forResource: "lagrange-export", withExtension: "mp4") else { return }
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
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
private enum LagrangeArchiveReader {
    static func read(_ url: URL) throws -> LagrangeUserDataExport {
        let names = try output(arguments: ["-Z1", url.path]).split(whereSeparator: \.isNewline).map(String.init)
        let wanted = names.filter { name in
            name == "lagrange-export.ini" || name == "bookmarks.ini" || name == "sitespec.ini"
                || name == "trusted.txt" || (name.hasPrefix("idents/") && (name.hasSuffix(".crt") || name.hasSuffix(".key")))
        }
        var files: [String: Data] = [:]
        for name in wanted {
            files[name] = try data(arguments: ["-p", url.path, name])
        }
        return try LagrangeUserDataExport(files: files)
    }

    private static func output(arguments: [String]) throws -> String {
        String(data: try data(arguments: arguments), encoding: .utf8) ?? ""
    }

    private static func data(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Validation errors are normalized to a corrupt-file message below. Leaving
        // stderr on a pipe without draining it can deadlock as well.
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting. `trusted.txt` commonly exceeds a pipe buffer; waiting
        // first causes unzip to block on the full pipe while the UI waits for unzip.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }
}

private struct ImportDataView: View {
    @StateObject private var model = ImportDataModel()
    @StateObject private var exportVideo = LagrangeExportVideoController()
    let dismiss: () -> Void
    let setWindowTitle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.step == 0 { sourceStep } else { lagrangeStep }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if model.step == 1 { Button("Back") { model.step = 0 } }
                Spacer()
                if model.step == 0 {
                    Button("Next") { model.step = 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.source != .lagrange)
                } else if model.resultMessage == nil {
                    Button(model.isImporting ? "Importing…" : "Import") { model.importExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.export == nil || model.isImporting)
                } else {
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
        .frame(width: 650, height: 600, alignment: .topLeading)
        .onAppear { updateWindowTitle() }
        .onChange(of: model.step) { _, _ in updateWindowTitle() }
    }

    private func updateWindowTitle() {
        setWindowTitle(model.step == 0 ? "Import Data from Other Clients" : "Import from Lagrange")
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import exported bookmarks, settings, client-side certificates, and identities from other Gemini Clients.")
            Picker("Gemini client", selection: $model.source) {
                ForEach(ImportDataModel.Source.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.radioGroup)
            Text(model.source == .lagrange
                 ? "Lagrange exports are supported."
                : "Importing from Alhena is not available yet.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var lagrangeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoopingVideoView(player: exportVideo.player)
                .frame(maxWidth: .infinity)
                .frame(height: 330)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Silent looping demonstration of exporting Lagrange user data")
            Text("In Lagrange, choose File > User Data > Export. Save the ZIP file, then choose it below.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Imports bookmarks, homepage, client certificates, identity assignments, and trusted capsule identities. Existing data is kept.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose UserData Export…") { model.chooseExport() }
                .disabled(model.isImporting)
            importStatus
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isImporting && model.export == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Lagrange export…").foregroundStyle(.secondary)
                }
            }
            if let selectedFileName = model.selectedFileName {
                Text("Selected: \(selectedFileName) (Lagrange \(model.export?.version ?? ""))").foregroundStyle(.secondary)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            if let progress = model.importProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    Text(progress.message).foregroundStyle(.secondary)
                }
            }
            if let result = model.resultMessage { Text(result).foregroundStyle(.secondary) }
        }
        .font(.body)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .topLeading)
    }
}

@MainActor
enum ImportDataWindowPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Import Data from Other Clients"
        let contentSize = NSSize(width: 650, height: 600)
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
