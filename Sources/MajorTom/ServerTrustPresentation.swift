import AppKit
import Combine
import Foundation
import MajorTomCore

struct TrustPrompt: Identifiable {
    let id: UUID
    let title: String
    let explanation: String
    let identity: PresentedServerIdentity
    let previousFingerprint: String?
}

/// UI presentation and live composition for the shared Core trust authority.
@MainActor
final class ServerTrustPresentation: ObservableObject {
    @Published private(set) var prompt: TrustPrompt?
    @Published private(set) var presenterWindow: NSWindow?
    @Published var failure: String?
    private let authority: ServerTrustAuthority
    private var observers: [NSObjectProtocol] = []

    init(store: TrustedIdentityStore?) {
        authority = ServerTrustAuthority(read: { endpoint in
            guard let store else { throw ServerTrustAuthorityError.storeUnavailable }
            return await store.identity(for: endpoint)
        }, save: { identity, source in
            guard let store else { throw ServerTrustAuthorityError.storeUnavailable }
            try await store.trust(identity, source: source)
        })
        authority.decisionChanged = { [weak self] decision in
            guard let self else { return }
            prompt = decision.map { Self.prompt(for: $0.challenge, id: $0.id) }
            selectPresenter()
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectPresenter() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.presenterWindow === window else { return }
                self.presenterWindow = nil
                self.selectPresenter(excluding: window)
            }
        })
    }

    func authorize(_ identity: PresentedServerIdentity) async -> Bool {
        do { return try await authority.authorize(identity) }
        catch is CancellationError { return false }
        catch ServerTrustAuthorityError.storeUnavailable {
            failure = "Major Tom could not open its trusted-identity store."
            selectPresenter()
            return false
        }
        catch {
            failure = "Major Tom could not verify or save this capsule's identity: \(error.localizedDescription)"
            selectPresenter()
            return false
        }
    }

    func respond(allow: Bool, promptID: UUID) {
        authority.respond(to: promptID, allow: allow)
    }

    func suspendAndDrain() async {
        failure = nil
        await authority.suspendAndDrain()
    }

    func resumeAuthorization() { authority.resumeAuthorization() }

    private func selectPresenter(excluding excluded: NSWindow? = nil) {
        guard prompt != nil || failure != nil else { presenterWindow = nil; return }
        if let presenterWindow, presenterWindow !== excluded, presenterWindow.isVisible { return }
        let key = NSApplication.shared.keyWindow
        let candidates = [key?.sheetParent ?? key].compactMap { $0 } + NSApplication.shared.windows
        presenterWindow = candidates.first {
            $0 !== excluded && $0.isVisible
                && $0.tabbingIdentifier == NativeTabCoordinator.tabbingIdentifier
                && ($0.tabGroup?.selectedWindow == nil || $0.tabGroup?.selectedWindow === $0)
        }
    }

    private static func prompt(for challenge: ServerTrustChallenge, id: UUID) -> TrustPrompt {
        switch challenge {
        case .firstUse(let presented):
            return TrustPrompt(
                id: id,
                title: "Trust This Capsule?",
                explanation: "This is the first time Major Tom has connected to this capsule. Confirm its identity before continuing.",
                identity: presented,
                previousFingerprint: nil
            )
        case .changed(let presented, let previous):
            return TrustPrompt(
                id: id,
                title: "Capsule Identity Changed",
                explanation: "The capsule is presenting a different public key. This can be legitimate, but it can also indicate an intercepted connection.",
                identity: presented,
                previousFingerprint: previous.publicKeySHA256
            )
        case .seedMismatch(let presented, let expected):
            return TrustPrompt(
                id: id,
                title: "Capsule Identity Does Not Match",
                explanation: "The presented public key does not match Major Tom's prior identity information.",
                identity: presented,
                previousFingerprint: expected.sorted().joined(separator: "\n")
            )
        case .invalidCertificateDates(let presented, let issue):
            let explanation: String
            switch issue {
            case .notYetValid(let date):
                explanation = "The capsule's certificate is not valid until \(date.formatted())."
            case .expired(let date):
                explanation = "The capsule's certificate expired on \(date.formatted())."
            }
            return TrustPrompt(
                id: id,
                title: "Certificate Date Warning",
                explanation: explanation,
                identity: presented,
                previousFingerprint: nil
            )
        }
    }

}
