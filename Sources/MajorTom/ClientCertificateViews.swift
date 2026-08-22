import AppKit
import MajorTomCore
import Security
import SecurityInterface
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
struct ClientCertificatesManagerView: View {
    @ObservedObject var store: ClientCertificateStore
    let openInNewTab: (URL) -> Void

    @State private var selectedID: UUID?
    @State private var showsCreation = false
    @State private var showsImport = false
    @State private var certificatePendingDeletion: ClientCertificateDescriptor?
    @State private var certificatePendingExport: ClientCertificateDescriptor?
    @State private var associationSortOrder = [
        KeyPathComparator(\AssociationRow.urlString)
    ]

    private struct AssociationRow: Identifiable {
        let association: ClientCertificateAssociation
        let destination: URL
        let urlString: String
        let scope: String

        var id: UUID { association.id }

        init(_ association: ClientCertificateAssociation) {
            self.association = association
            var components = URLComponents()
            components.scheme = "gemini"
            components.host = association.endpoint.host
            if association.endpoint.port != GeminiRequestTarget.defaultPort {
                components.port = Int(association.endpoint.port)
            }
            components.percentEncodedPath = association.pathPrefix
            destination = components.url ?? URL(string: "gemini://invalid/")!
            urlString = destination.absoluteString
            scope = association.scope == .entireCapsule
                ? "Entire capsule"
                : "This URL and below"
        }
    }

    private var selected: ClientCertificateDescriptor? {
        store.certificates.first { $0.id == selectedID } ?? store.certificates.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                certificateList
                    .frame(width: 300)
                Divider()
                detail
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            selectedID = store.consumeManagerSelectionRequest()
                ?? selectedID
                ?? store.certificates.first?.id
            store.refreshAvailability()
        }
        .sheet(isPresented: $showsCreation) {
            ClientCertificateCreationView(store: store) { certificate in
                selectedID = certificate.id
                showsCreation = false
            } cancel: {
                showsCreation = false
            }
        }
        .sheet(isPresented: $showsImport) {
            ClientCertificateImportView(store: store) { certificate in
                selectedID = certificate.id
                showsImport = false
            } cancel: {
                showsImport = false
            }
        }
        .alert(
            "Delete Client Certificate?",
            isPresented: Binding(
                get: { certificatePendingDeletion != nil },
                set: { if !$0 { certificatePendingDeletion = nil } }
            ),
            presenting: certificatePendingDeletion
        ) { certificate in
            Button("Cancel", role: .cancel) { certificatePendingDeletion = nil }
            Button("Delete", role: .destructive) {
                certificatePendingDeletion = nil
                Task {
                    do {
                        try await store.delete(certificate)
                        selectedID = store.certificates.first?.id
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
            }
        } message: { certificate in
            Text("Deleting “\(certificate.commonName)” removes its private key, all saved capsule associations, and synchronized copies on your other Macs. You may permanently lose access to accounts registered with it.")
        }
        .alert(
            "Export Client Identity?",
            isPresented: Binding(
                get: { certificatePendingExport != nil },
                set: { if !$0 { certificatePendingExport = nil } }
            ),
            presenting: certificatePendingExport
        ) { certificate in
            Button("Cancel", role: .cancel) { certificatePendingExport = nil }
            Button("Export Identity…") {
                certificatePendingExport = nil
                exportIdentity(certificate)
            }
        } message: { certificate in
            Text("The exported PEM file contains the private key for “\(certificate.commonName)”. Anyone with this file can use this identity. Store it securely and delete it after importing.")
        }
        .alert("Client Certificate Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Client Certificates", systemImage: "person.badge.key")
                .font(.headline)
            Spacer()
            Button("Import…", systemImage: "square.and.arrow.down") { showsImport = true }
            Button("New Client Certificate", systemImage: "plus") { showsCreation = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var certificateList: some View {
        if store.certificates.isEmpty {
            ContentUnavailableView {
                Label("No Client Certificates", systemImage: "person.badge.key")
            } description: {
                Text("Use New Client Certificate above to create an identity.")
            }
        } else {
            List(selection: $selectedID) {
                ForEach(store.certificates.sorted(by: certificateSort)) { certificate in
                    HStack(spacing: 9) {
                        Image(systemName: statusSymbol(certificate))
                            .foregroundStyle(statusColor(certificate))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(certificate.commonName)
                                .lineLimit(1)
                            Text(certificate.notAfter, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(certificate.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let certificate = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let certificateDER = store.certificateDER(for: certificate) {
                        NativeCertificateDetailsView(certificateDER: certificateDER)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        ContentUnavailableView {
                            Label("Certificate Unavailable", systemImage: "icloud.slash")
                        } description: {
                            Text("The certificate and private key have not arrived from iCloud Keychain on this Mac yet.")
                        }
                        .frame(minHeight: 260)
                    }

                    HStack {
                        Text(store.availability[certificate.id] == false
                            ? "Private key is not available on this Mac yet."
                            : certificate.synchronizesWithICloud
                                ? "Stored in iCloud Keychain"
                                : "Stored in Keychain on this Mac")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Public Certificate") { copyPEM(certificate) }
                            .disabled(store.certificatePEM(for: certificate) == nil)
                        Button("Export Identity…") {
                            certificatePendingExport = certificate
                        }
                        .disabled(store.availability[certificate.id] == false)
                        Button("Delete…", role: .destructive) {
                            certificatePendingDeletion = certificate
                        }
                    }

                    GroupBox("Approved Capsule Scopes") {
                        let associations = store.associations(for: certificate)
                        if associations.isEmpty {
                            Text("This identity is not currently sent to any capsule.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        } else {
                            Table(
                                associations.map(AssociationRow.init).sorted(using: associationSortOrder),
                                sortOrder: $associationSortOrder
                            ) {
                                TableColumn("URL", value: \.urlString) { row in
                                    Button(row.urlString) {
                                        openInNewTab(row.destination)
                                    }
                                    .buttonStyle(.link)
                                    .help("Open in a new tab")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .width(min: 180, ideal: 500, max: .infinity)
                                .alignment(.leading)
                                TableColumn("Scope", value: \.scope) { row in
                                    Picker("Scope", selection: Binding(
                                        get: { row.association.scope },
                                        set: { store.changeAssociationScope(id: row.id, to: $0) }
                                    )) {
                                        Text("Entire capsule")
                                            .tag(ClientCertificateScopeChoice.entireCapsule)
                                        Text("This URL and below")
                                            .tag(ClientCertificateScopeChoice.pathAndDescendants)
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }
                                .width(min: 170, ideal: 210, max: 240)
                                TableColumn("Actions") { row in
                                    Menu {
                                        Button("Remove Association", role: .destructive) {
                                            store.removeAssociation(id: row.id)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .width(80)
                                .alignment(.trailing)
                            }
                            .frame(minHeight: 170)
                        }
                    }
                }
                .padding(22)
            }
        } else {
            ContentUnavailableView("Select a Certificate", systemImage: "person.badge.key")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusSymbol(_ certificate: ClientCertificateDescriptor) -> String {
        if !certificate.isValid() { return "exclamationmark.triangle.fill" }
        if store.availability[certificate.id] == false { return "icloud.slash" }
        return "checkmark.seal.fill"
    }

    private func statusColor(_ certificate: ClientCertificateDescriptor) -> Color {
        if !certificate.isValid() { return .red }
        if store.availability[certificate.id] == false { return .orange }
        return .green
    }

    private func certificateSort(_ lhs: ClientCertificateDescriptor, _ rhs: ClientCertificateDescriptor) -> Bool {
        lhs.commonName.localizedStandardCompare(rhs.commonName) == .orderedAscending
    }

    private func copyPEM(_ certificate: ClientCertificateDescriptor) {
        guard let pem = store.certificatePEM(for: certificate) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pem, forType: .string)
    }

    private func exportIdentity(_ certificate: ClientCertificateDescriptor) {
        Task {
            let panel = NSSavePanel()
            panel.title = "Export Client Identity"
            panel.prompt = "Export"
            panel.nameFieldStringValue = exportFilename(for: certificate)
            panel.canCreateDirectories = true
            if let pemType = UTType(filenameExtension: "pem") {
                panel.allowedContentTypes = [pemType]
            }
            guard await panel.begin() == .OK, let destination = panel.url else { return }

            do {
                let pem = try await store.exportIdentityPEM(for: certificate)
                try await Task.detached(priority: .userInitiated) {
                    let data = Data(pem.utf8)
                    try data.write(to: destination, options: .atomic)

                    // Harden the file where POSIX modes exist. FAT volumes and some
                    // network shares do not implement chmod; a successful write remains
                    // a successful export on those destinations.
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: destination.path
                    )
                }.value
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    private func exportFilename(for certificate: ClientCertificateDescriptor) -> String {
        let invalid = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let sanitized = certificate.commonName
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(sanitized.isEmpty ? "client-identity" : sanitized).pem"
    }

}

/// SwiftUI bridge for Apple's standard certificate inspector used throughout macOS.
@available(macOS 26.0, *)
private struct NativeCertificateDetailsView: NSViewRepresentable {
    let certificateDER: Data
    var detailsDisclosed = true

    func makeNSView(context: Context) -> SFCertificateView {
        let view = SFCertificateView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: SFCertificateView, context: Context) {
        configure(view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView view: SFCertificateView,
        context: Context
    ) -> CGSize? {
        let width = max(320, proposal.width ?? view.fittingSize.width)
        if view.frame.width != width {
            view.setFrameSize(NSSize(width: width, height: max(1, view.frame.height)))
        }
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        guard height.isFinite, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func configure(_ view: SFCertificateView) {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            return
        }
        view.setCertificate(certificate)
        view.setDisplayTrust(false)
        view.setEditableTrust(false)
        view.setDisplayDetails(true)
        view.setDetailsDisclosed(detailsDisclosed)
    }
}

@available(macOS 26.0, *)
private struct ClientCertificateImportView: View {
    @ObservedObject var store: ClientCertificateStore
    let completion: (ClientCertificateDescriptor) -> Void
    let cancel: () -> Void

    @State private var imported: ClientCertificateImport?
    @State private var errorMessage: String?
    @State private var showsFileImporter = false
    @State private var isImporting = false
    @State private var pastedChangeCount: Int?
    @State private var clearsClipboard = true

    private static let allowedTypes: [UTType] = {
        var types = [UTType.plainText]
        if let pem = UTType(filenameExtension: "pem") { types.insert(pem, at: 0) }
        if let key = UTType(filenameExtension: "key") { types.append(key) }
        if let certificate = UTType(filenameExtension: "crt") { types.append(certificate) }
        return types
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Client Identity")
                .font(.headline)

            Text("Paste a PEM-encoded client certificate and its matching private key.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let imported {
                NativeCertificateDetailsView(
                    certificateDER: imported.certificateDER,
                    detailsDisclosed: false
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Label("Matching private key found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if pastedChangeCount != nil {
                    Toggle("Clear the copied private key from the clipboard after importing", isOn: $clearsClipboard)
                }
            } else {
                ContentUnavailableView(
                    "Paste a Client Identity",
                    systemImage: "doc.on.clipboard"
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Paste from Clipboard", systemImage: "clipboard") {
                    pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Choose File…", systemImage: "folder") {
                    showsFileImporter = true
                }

                Spacer()

                Button("Cancel", role: .cancel) { cancel() }
                Button("Import") { performImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(imported == nil || isImporting)
            }

            if isImporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(width: 660)
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importFile(url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            imported = nil
            pastedChangeCount = nil
            errorMessage = "The clipboard does not contain PEM text."
            return
        }
        load(text, pastedChangeCount: pasteboard.changeCount)
    }

    private func importFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 10 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ClientCertificatePEMError.invalidCertificate
            }
            load(text, pastedChangeCount: nil)
        } catch {
            imported = nil
            pastedChangeCount = nil
            errorMessage = error.localizedDescription
        }
    }

    private func load(_ pem: String, pastedChangeCount: Int?) {
        do {
            imported = try ClientCertificateImport.parse(pem: pem)
            self.pastedChangeCount = pastedChangeCount
            errorMessage = nil
        } catch {
            imported = nil
            self.pastedChangeCount = nil
            errorMessage = error.localizedDescription
        }
    }

    private func performImport() {
        guard let imported else { return }
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let descriptor = try await store.importIdentity(imported)
                if clearsClipboard,
                   let pastedChangeCount,
                   NSPasteboard.general.changeCount == pastedChangeCount {
                    NSPasteboard.general.clearContents()
                }
                completion(descriptor)
            } catch {
                errorMessage = error.localizedDescription
                isImporting = false
            }
        }
    }
}

@available(macOS 26.0, *)
struct ClientCertificateCreationView: View {
    @ObservedObject var store: ClientCertificateStore
    let completion: (ClientCertificateDescriptor) -> Void
    let cancel: () -> Void

    @State private var commonName = ""
    @State private var emailAddress = ""
    @State private var userID = ""
    @State private var domain = ""
    @State private var organization = ""
    @State private var country = ""
    @State private var validUntil = Calendar.current.date(byAdding: .year, value: 5, to: Date())!
    @State private var showsAdditionalDetails = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var commonNameFocused: Bool

    private var canCreate: Bool {
        !commonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validUntil > Date()
            && (country.isEmpty || country.trimmingCharacters(in: .whitespacesAndNewlines).count == 2)
            && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Client Certificate").font(.headline)
            Text("A Gemini capsule can see every value placed in this certificate. Only the common name is required.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Common Name", text: $commonName)
                    .focused($commonNameFocused)
                DatePicker("Valid Until", selection: $validUntil, displayedComponents: [.date])

                DisclosureGroup("Additional Certificate Details", isExpanded: $showsAdditionalDetails) {
                    TextField("Email", text: $emailAddress)
                    TextField("User ID", text: $userID)
                    TextField("Domain", text: $domain)
                    TextField("Organization", text: $organization)
                    TextField("Country Code", text: $country)
                        .onChange(of: country) { _, value in
                            country = String(value.uppercased().prefix(2))
                        }
                }
            }
            .formStyle(.grouped)

            Text("The private key will be stored in Keychain and synchronized through iCloud Keychain. Losing every copy may mean losing accounts registered with this certificate.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .disabled(isCreating)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { commonNameFocused = true }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let request = ClientCertificateCreationRequest(
            commonName: commonName,
            emailAddress: emailAddress,
            userID: userID,
            domain: domain,
            organization: organization,
            country: country,
            validUntil: validUntil
        )
        Task {
            do {
                let certificate = try await store.create(request)
                completion(certificate)
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

@available(macOS 26.0, *)
struct ClientCertificatePromptView: View {
    let prompt: BrowserModel.ClientCertificatePrompt
    @ObservedObject var store: ClientCertificateStore
    let use: (UUID, ClientCertificateScopeChoice) -> Void
    let stopUsing: () -> Void
    let cancel: () -> Void

    @State private var selectedID: UUID?
    @State private var scope = ClientCertificateScopeChoice.authenticationDefault
    @State private var showsCreation = false

    private var choices: [ClientCertificateDescriptor] {
        store.validCertificates.filter {
            store.availability[$0.id] != false && $0.id != prompt.attemptedCertificate?.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "person.badge.key")
                .font(.headline)
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
            if !prompt.message.isEmpty {
                Text(prompt.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(prompt.target.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            if prompt.matchingCertificateIsUnavailable {
                Label(
                    "The approved certificate is not available from iCloud Keychain on this Mac yet.",
                    systemImage: "icloud.slash"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if prompt.matchingCertificateIsInvalid {
                Label(
                    "The certificate approved for this address is expired or not valid yet.",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if choices.isEmpty {
                ContentUnavailableView {
                    Label("No Available Certificate", systemImage: "person.badge.key")
                } description: {
                    Text("Create a client certificate to continue.")
                } actions: {
                    Button("Create Certificate…") { showsCreation = true }
                }
                .frame(minHeight: 150)
            } else {
                Form {
                    Picker("Client Certificate", selection: $selectedID) {
                        Text("Select…").tag(nil as UUID?)
                        ForEach(choices) { certificate in
                            Text("\(certificate.commonName) — expires \(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))")
                                .tag(certificate.id as UUID?)
                        }
                    }
                    Picker("Use For", selection: $scope) {
                        Text("Entire capsule").tag(ClientCertificateScopeChoice.entireCapsule)
                        Text("This URL and below").tag(ClientCertificateScopeChoice.pathAndDescendants)
                    }
                }
                .formStyle(.grouped)

                Text(scopeExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Create Another Certificate…") { showsCreation = true }
            }

            Text("A capsule receives the certificate's public identity when it is offered. With TLS 1.2, certificate metadata may be visible to an observer of the handshake.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if hasSavedAssociation {
                    Button("Stop Using Approved Certificate", role: .destructive, action: stopUsing)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Use Certificate") {
                    guard let selectedID else { return }
                    use(selectedID, scope)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear {
            selectedID = choices.first?.id
            store.refreshAvailability()
        }
        .sheet(isPresented: $showsCreation) {
            ClientCertificateCreationView(store: store) { certificate in
                selectedID = certificate.id
                showsCreation = false
            } cancel: {
                showsCreation = false
            }
        }
    }

    private var hasSavedAssociation: Bool {
        prompt.attemptedCertificate != nil
            || prompt.matchingCertificateIsUnavailable
            || prompt.matchingCertificateIsInvalid
    }

    private var scopeExplanation: String {
        switch scope {
        case .entireCapsule:
            "Major Tom will offer this identity throughout \(prompt.target.endpoint.host), including sibling paths used after sign-in."
        case .pathAndDescendants:
            "Major Tom will offer this identity only at \(ClientCertificateAssociation.requestPath(for: prompt.target.url)) and URLs below it. Sibling paths will not receive it."
        }
    }

    private var title: String {
        switch prompt.status {
        case 60: "Client Certificate Required"
        case 61: "Client Certificate Not Authorized"
        case 62: "Client Certificate Not Valid"
        default: "Client Certificate Required"
        }
    }

    private var explanation: String {
        switch prompt.status {
        case 61:
            "The capsule did not authorize \(prompt.attemptedCertificate?.commonName ?? "the selected certificate") for this resource. Choose a different identity or cancel."
        case 62:
            "The capsule rejected \(prompt.attemptedCertificate?.commonName ?? "the selected certificate") as invalid. Choose a different identity or create a replacement."
        default:
            "This capsule requires a client certificate. Choose an identity and explicitly approve where Major Tom may offer it."
        }
    }
}
