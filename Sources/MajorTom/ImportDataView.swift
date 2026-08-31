import AppKit
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
        Task {
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
        Task {
            var importedCertificates = 0
            var associations = 0
            var certificatesByDigest: [String: UUID] = [:]
            for identity in export.identities {
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
            for assignment in export.identityAssignments {
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
            for identity in export.trustedIdentities {
                try? await SharedTrustedIdentityStore.shared?.trust(
                    PresentedServerIdentity(endpoint: identity.endpoint, publicKeySHA256: identity.publicKeySHA256),
                    source: .user
                )
            }
            BookmarksModel.shared.importLagrangeBookmarks(export.bookmarks)
            if let homepage = export.bookmarks.first(where: \.isHomepage) {
                var preferences = BrowserSettingsStore.shared.preferences
                preferences.homepage = homepage.url.absoluteString
                BrowserSettingsStore.shared.preferences = preferences
            }
            isImporting = false
            resultMessage = "Imported \(export.bookmarks.count) bookmarks, \(importedCertificates) client certificates, and \(associations) identity assignments."
        }
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
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.step == 0 { sourceStep } else { lagrangeStep }
            Divider()
            HStack {
                if model.step == 1 { Button("Back") { model.step = 0 } }
                Spacer()
                Button("Cancel", action: dismiss)
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
        }
        .padding(24)
        .frame(width: 610)
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Data from Other Client").font(.title2)
            Text("Import exported bookmarks, settings, client-side certificates, and identities from other Gemini Clients.")
            Picker("Gemini client", selection: $model.source) {
                ForEach(ImportDataModel.Source.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.radioGroup)
            if model.source == .alhena {
                Text("Importing from Alhena is not available yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var lagrangeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Lagrange").font(.title2)
            Text("In Lagrange:")
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Choose File > User Data > Export.")
                Text("2. Save the export to your Downloads folder.")
                Text("3. Choose that ZIP file below.")
            }
            Text("Major Tom imports bookmarks, the first homepage bookmark, client certificates, per-path identity assignments, and trusted capsule identities.")
            Button("Choose UserData Export…") { model.chooseExport() }
                .disabled(model.isImporting)
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
            if let result = model.resultMessage { Text(result).foregroundStyle(.secondary) }
        }
    }
}

@MainActor
enum ImportDataWindowPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Import Data from Other Client"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: ImportDataView { panel.close() })
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
