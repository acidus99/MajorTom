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

    enum ParsedExport {
        case lagrange(LagrangeUserDataExport)
        case alhena(AlhenaUserDataExport)

        var version: String {
            switch self {
            case .lagrange(let value): value.version
            case .alhena(let value): value.version
            }
        }
    }

    @Published var source: Source = .lagrange
    @Published var step = 0
    @Published var export: ParsedExport?
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var resultItems: [String]?
    @Published var importProgress: (completed: Int, total: Int, message: String)?

    func sourceChanged() {
        export = nil
        errorMessage = nil
        resultItems = nil
        importProgress = nil
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
        isImporting = true
        Task { @MainActor in
            do {
                // A User Data export can contain a large trust database. Reading it on
                // the main actor used to leave the app unable to redraw while unzip was
                // producing output.
                let parsedExport = try await Task.detached(priority: .userInitiated) {
                    switch selectedSource {
                    case .lagrange: ParsedExport.lagrange(try LagrangeArchiveReader.read(url))
                    case .alhena: ParsedExport.alhena(try AlhenaArchiveReader.read(url))
                    }
                }.value
                export = parsedExport
            } catch {
                self.export = nil
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    func importExport() {
        guard let export else { return }
        step = 2
        isImporting = true
        errorMessage = nil
        resultItems = nil
        Task { @MainActor in
            // Give SwiftUI an opportunity to present the progress screen before any
            // import work begins.
            await Task.yield()
            switch export {
            case .lagrange(let value): await importLagrange(value)
            case .alhena(let value): await importAlhena(value)
            }
            isImporting = false
            importProgress = nil
        }
    }

    private func importLagrange(_ export: LagrangeUserDataExport) async {
        var importedCertificates = 0
        var associations = 0
        var importedTrust = 0
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
                let (parsed, digest) = try await Self.parseIdentity(
                    certificatePEM: identity.certificatePEM,
                    privateKeyPEM: identity.privateKeyPEM
                )
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
            if index.isMultiple(of: 25) { await Task.yield() }
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
        let trustedIdentities = await Task.detached(priority: .userInitiated) {
            export.trustedIdentities.map {
                PresentedServerIdentity(endpoint: $0.endpoint, publicKeySHA256: $0.publicKeySHA256)
            }
        }.value
        importedTrust = (try? await SharedTrustedIdentityStore.shared?
            .importTrustedIdentities(trustedIdentities)) ?? 0
        completedSteps += 1
        reportProgress("Importing bookmarks and settings…")
        let importedBookmarks = await BookmarksModel.shared.importLagrangeBookmarks(export.bookmarks)
        var importedHomepage = false
        if let homepage = export.bookmarks.first(where: \.isHomepage) {
            var preferences = BrowserSettingsStore.shared.preferences
            preferences.homepage = homepage.url.absoluteString
            BrowserSettingsStore.shared.preferences = preferences
            importedHomepage = true
        }
        completedSteps += 1
        var items: [String] = []
        Self.appendCount(importedBookmarks, singular: "Bookmark", plural: "Bookmarks", to: &items)
        Self.appendCount(importedCertificates, singular: "Client-side Certificate", plural: "Client-side Certificates", to: &items)
        Self.appendCount(associations, singular: "Identity Assignment", plural: "Identity Assignments", to: &items)
        Self.appendCount(importedTrust, singular: "Trusted Capsule Identity", plural: "Trusted Capsule Identities", to: &items)
        if importedHomepage { items.append("Homepage") }
        resultItems = items
    }

    private func importAlhena(_ export: AlhenaUserDataExport) async {
        var importedCertificates = 0
        var associations = 0
        let totalSteps = max(1, export.identities.count + 1)
        var completedSteps = 0

        for (index, identity) in export.identities.enumerated() {
            importProgress = (completedSteps, totalSteps,
                              "Importing client certificate \(index + 1) of \(export.identities.count)…")
            defer { completedSteps += 1 }
            do {
                let (parsed, digest) = try await Self.parseIdentity(
                    certificatePEM: identity.certificatePEM,
                    privateKeyPEM: identity.privateKeyPEM
                )
                let isAlreadyImported = ClientCertificateStore.shared.certificates.contains {
                    $0.certificateSHA256 == digest
                }
                let descriptor = try await ClientCertificateStore.shared.importIdentity(parsed)
                if !isAlreadyImported { importedCertificates += 1 }

                if identity.isActive, let url = identity.url,
                   let proposed = ClientCertificateAssociation.pathAndDescendants(
                    certificateID: descriptor.id, url: url
                   ), !ClientCertificateStore.shared.associations.contains(where: {
                    $0.endpoint == proposed.endpoint
                        && $0.scope == proposed.scope
                        && $0.pathPrefix == proposed.pathPrefix
                   }) {
                    ClientCertificateStore.shared.associate(
                        certificateID: descriptor.id, with: url, scope: .pathAndDescendants
                    )
                    associations += 1
                }
            } catch {
                continue
            }
        }

        importProgress = (completedSteps, totalSteps, "Importing bookmarks and settings…")
        let importedBookmarks = await BookmarksModel.shared.importAlhenaBookmarks(export.bookmarks)
        var preferences = BrowserSettingsStore.shared.preferences
        var importedHomepage = false
        var importedSearch = false
        var importedProxy = false
        var importedTheme = false
        if let homepage = export.preferences["home"], URL(string: homepage) != nil {
            preferences.homepage = homepage
            importedHomepage = true
        }
        if let searchURL = export.preferences["searchurl"], URL(string: searchURL) != nil {
            preferences.searchProvider = .custom
            preferences.customSearchEndpoint = searchURL
            importedSearch = true
        }
        if let proxy = export.preferences["httpproxy"].flatMap(Self.proxyConfiguration) {
            preferences.proxy = proxy
            importedProxy = true
        }
        if let theme = export.preferences["theme"]?.lowercased() {
            if theme.contains("dark") {
                preferences.applicationAppearance = .dark
                importedTheme = true
            } else if theme.contains("light") {
                preferences.applicationAppearance = .light
                importedTheme = true
            }
        }
        BrowserSettingsStore.shared.preferences = preferences
        var items: [String] = []
        Self.appendCount(importedBookmarks, singular: "Bookmark", plural: "Bookmarks", to: &items)
        Self.appendCount(importedCertificates, singular: "Client-side Certificate", plural: "Client-side Certificates", to: &items)
        Self.appendCount(associations, singular: "Identity Assignment", plural: "Identity Assignments", to: &items)
        if importedHomepage { items.append("Homepage") }
        if importedTheme { items.append("UI Theme") }
        if importedProxy { items.append("HTTP Proxy") }
        if importedSearch { items.append("Search Engine") }
        resultItems = items
    }

    private static func parseIdentity(
        certificatePEM: String,
        privateKeyPEM: String
    ) async throws -> (ClientCertificateImport, String) {
        try await Task.detached(priority: .userInitiated) {
            let parsed = try ClientCertificateImport.parse(pem: certificatePEM + "\n" + privateKeyPEM)
            return (parsed, CertificateDetails.sha256(certificateDER: parsed.certificateDER))
        }.value
    }

    private static func appendCount(
        _ count: Int,
        singular: String,
        plural: String,
        to items: inout [String]
    ) {
        guard count > 0 else { return }
        items.append("\(count) \(count == 1 ? singular : plural)")
    }

    private static func proxyConfiguration(_ value: String) -> GeminiProxyConfiguration? {
        guard let components = URLComponents(string: "gemini://\(value)"),
              let host = components.host, !host.isEmpty,
              let port = components.port, let validPort = UInt16(exactly: port) else { return nil }
        return GeminiProxyConfiguration(host: host, port: validPort)
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

/// Reads only Alhena's two documented export members and never executes script.sql.
private enum AlhenaArchiveReader {
    static func read(_ url: URL) throws -> AlhenaUserDataExport {
        let names = try ArchiveReader.output(arguments: ["-Z1", url.path])
            .split(whereSeparator: \.isNewline).map(String.init)
        var files: [String: Data] = [:]
        for name in ["version.txt", "script.sql"] where names.contains(name) {
            files[name] = try ArchiveReader.data(arguments: ["-p", url.path, name])
        }
        return try AlhenaUserDataExport(files: files)
    }
}

private enum ArchiveReader {
    static func output(arguments: [String]) throws -> String {
        String(data: try data(arguments: arguments), encoding: .utf8) ?? ""
    }

    static func data(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }
}

private struct ImportDataView: View {
    @StateObject private var model = ImportDataModel()
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
                        .disabled(model.export == nil || model.isImporting)
                } else if !model.isImporting {
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
        .onChange(of: model.isImporting) { _, _ in updateWindowTitle() }
        .onChange(of: model.source) { _, _ in model.sourceChanged() }
    }

    private func updateWindowTitle() {
        let title = switch model.step {
        case 0: "Import Data from Other Clients"
        case 1: "Import from \(model.source.rawValue)"
        default: model.isImporting ? "Importing from \(model.source.rawValue)" : "Import Complete"
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
                .disabled(model.isImporting)
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
            if model.isImporting && model.export == nil {
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
            if model.isImporting {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Importing data from \(model.source.rawValue)…")
                        .font(.title2)
                    if let progress = model.importProgress {
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
            } else {
                VStack(alignment: .center, spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Import complete")
                    Text("Your data was imported from \(model.source.rawValue).")
                        .font(.title2)
                    if let items = model.resultItems, !items.isEmpty {
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
