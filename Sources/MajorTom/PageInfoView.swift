import AppKit
import MajorTomCore
import SwiftUI

/// Everything the Page Info panel reports about the page currently on screen.
struct PageInformation: Identifiable {
    let id = UUID()
    var url: URL
    var status: Int?
    var meta: String
    var byteCount: Int
    var mimeType: String
    /// Absent for a local file, a generated error page, or a page restored from cache
    /// without reconnecting.
    var identity: PresentedServerIdentity?
    var trusted: TrustedServerIdentity?
}

/// Page and certificate information, in the spirit of Lagrange's panel.
///
/// The check list deliberately omits "Verified by CA". Nearly every Gemini capsule is
/// self-signed, so that row would show a red cross almost everywhere and teach the reader
/// to ignore the whole list. What replaces it is a plain statement of what Major Tom
/// actually relies on. The layout keeps room for a certificate-authority section later,
/// when this view is reused for a browser that speaks more than Gemini.
@available(macOS 26.0, *)
struct PageInfoView: View {
    let information: PageInformation
    let dismiss: () -> Void
    @State private var copied: String?

    private enum CheckState {
        case passed, failed, unknown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Page Information")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
                Text(responseSummary)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(byteSummary)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text("Certificate Status")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)

                check("Domain name matches", state: domainMatches)
                check("Not Expired", detail: expiryTimestamp, state: notExpired)
                check(trustLabel, state: isTrusted)

                Text(tofuExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                fingerprintsMenu
                if let copied {
                    Text(copied)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    // MARK: - Summary lines

    private var responseSummary: String {
        let status = information.status.map(String.init) ?? "\u{2014}"
        let meta = information.meta.isEmpty ? information.mimeType : information.meta
        return meta.isEmpty ? status : "\(status) \(meta)"
    }

    private var byteSummary: String {
        let formatted = information.byteCount.formatted(.number)
        return information.byteCount == 1 ? "1 byte" : "\(formatted) bytes"
    }

    // MARK: - Checks

    /// Whether the certificate even claims the host that was asked for. Worth showing
    /// separately from trust: a self-signed certificate for the wrong name is a signal no
    /// matter who signed it.
    private var domainMatches: CheckState {
        if let identity = information.identity,
           let der = identity.certificateDER {
            return CertificateSubject.matches(host: identity.endpoint.host, certificateDER: der)
                ? .passed
                : .failed
        }
        // Restored pages have no live TLS identity, but the trust record retains the
        // certificate most recently presented by this exact endpoint.
        if let trusted = information.trusted,
           let pem = trusted.certificatePEM,
           let der = CertificateDetails.der(certificatePEM: pem) {
            return CertificateSubject.matches(host: trusted.endpoint.host, certificateDER: der)
                ? .passed
                : .failed
        }
        return .unknown
    }

    private var notExpired: CheckState {
        guard let certificateExpiry else { return .unknown }
        return certificateExpiry > Date() ? .passed : .failed
    }

    private var isTrusted: CheckState {
        guard let trusted = information.trusted else { return .unknown }
        guard let identity = information.identity else { return .passed }
        return trusted.publicKeySHA256.caseInsensitiveCompare(identity.publicKeySHA256) == .orderedSame
            ? .passed
            : .failed
    }

    private var expiryTimestamp: String? {
        certificateExpiry.map(Self.expiryFormatter.string(from:))
    }

    private var certificateExpiry: Date? {
        information.identity?.certificateNotAfter
            ?? information.trusted?.certificateNotAfter
            ?? information.trusted?.certificatePEM.flatMap {
                CertificateDetails.validityDates(certificatePEM: $0).notAfter
            }
    }

    private var trustLabel: String {
        guard let trusted = information.trusted else { return "Trusted" }
        let sourceText = trusted.source == .seed ? "from seed list" : "on first use"
        let sightings = trusted.timesSeen == 1 ? "seen once" : "seen \(trusted.timesSeen) times"
        return "Trusted \(sourceText), \(sightings)"
    }

    private var tofuExplanation: String {
        switch (information.identity, information.trusted) {
        case (.some, .none):
            return "Gemini TOFU mode: this capsule's key is not pinned yet. Major Tom pins the key it sees on first use and warns if it later changes."
        default:
            return "Gemini TOFU mode: capsules are identified by their public key, not by a certificate authority. Major Tom pins the key it first sees and warns you if it changes, so a self-signed certificate is normal and expected here."
        }
    }

    @ViewBuilder
    private func check(_ label: String, detail: String? = nil, state: CheckState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: state))
                .foregroundStyle(colour(for: state))
                .accessibilityHidden(true)
            Text(label)
            if let detail {
                Text(detail)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label)\(detail.map { ", \($0)" } ?? ""): \(description(for: state))"
        )
    }

    private func symbol(for state: CheckState) -> String {
        switch state {
        case .passed: "checkmark.square.fill"
        case .failed: "xmark.square.fill"
        case .unknown: "minus.square"
        }
    }

    private func colour(for state: CheckState) -> Color {
        switch state {
        case .passed: .green
        case .failed: .red
        case .unknown: .secondary
        }
    }

    private func description(for state: CheckState) -> String {
        switch state {
        case .passed: "yes"
        case .failed: "no"
        case .unknown: "not known"
        }
    }

    // MARK: - Fingerprints

    /// Two different digests, easy to confuse, so each is copied explicitly rather than
    /// through one ambiguous "copy fingerprint" button.
    private var fingerprintsMenu: some View {
        Menu("Fingerprints") {
            Button("Copy Certificate SHA-256") {
                copy(certificateFingerprint, named: "Certificate SHA-256")
            }
            .disabled(certificateFingerprint == nil)

            Button("Copy Public Key SHA-256") {
                copy(publicKeyFingerprint, named: "Public key SHA-256")
            }
            .disabled(publicKeyFingerprint == nil)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(certificateFingerprint == nil && publicKeyFingerprint == nil)
    }

    private var certificateFingerprint: String? {
        information.identity?.certificateSHA256 ?? information.trusted?.certificateSHA256
    }

    private var publicKeyFingerprint: String? {
        information.identity?.publicKeySHA256 ?? information.trusted?.publicKeySHA256
    }

    private func copy(_ value: String?, named name: String) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = "\(name) copied"
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed pattern rather than a localised style: this is a value someone compares
        // character by character against other tooling.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'GMT'"
        return formatter
    }()
}
