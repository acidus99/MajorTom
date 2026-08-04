@preconcurrency import Network
import Foundation
import Security

public enum GeminiTransportEvent: Equatable, Sendable {
    case connecting(CapsuleEndpoint)
    case serverIdentity(PresentedServerIdentity)
    case responseHeader(GeminiResponseHeader)
    case body(Data)
    case completed
}

public enum GeminiTransportError: Error, Sendable {
    case certificateUnavailable
    case publicKeyFingerprintFailed
    case trustDeclined
    case connectionFailed(String)
    case responseFailed(GeminiProtocolError)
    case timedOut
    case responseTooLarge(limit: Int)
}

public struct GeminiTransportConfiguration: Equatable, Sendable {
    public var idleTimeout: Duration
    public var maximumResponseByteCount: Int

    public init(
        idleTimeout: Duration = .seconds(30),
        maximumResponseByteCount: Int = 64 * 1_024 * 1_024
    ) {
        self.idleTimeout = idleTimeout
        self.maximumResponseByteCount = maximumResponseByteCount
    }
}

public final class GeminiTransport: @unchecked Sendable {
    public typealias TrustAuthorization = @Sendable (
        _ identity: PresentedServerIdentity,
        _ certificateDER: Data
    ) async -> Bool

    public init() {}

    public func events(
        for target: GeminiRequestTarget,
        configuration: GeminiTransportConfiguration = GeminiTransportConfiguration(),
        authorizeTrust: @escaping TrustAuthorization
    ) -> AsyncThrowingStream<GeminiTransportEvent, any Error> {
        AsyncThrowingStream { continuation in
            let session = GeminiConnectionSession(
                target: target,
                configuration: configuration,
                continuation: continuation,
                authorizeTrust: authorizeTrust
            )
            session.start()

            continuation.onTermination = { _ in
                session.cancel()
            }
        }
    }

}

private final class GeminiConnectionSession: @unchecked Sendable {
    private let target: GeminiRequestTarget
    private let configuration: GeminiTransportConfiguration
    private let continuation: AsyncThrowingStream<GeminiTransportEvent, any Error>.Continuation
    private let authorizeTrust: GeminiTransport.TrustAuthorization
    private let queue = DispatchQueue(label: "dev.gemi.major-tom.gemini-transport")

    private var connection: NWConnection?
    private var responseDecoder = GeminiResponseStreamDecoder()
    private var hasFinished = false
    private var receivedByteCount = 0
    private var timeoutTask: Task<Void, Never>?

    init(
        target: GeminiRequestTarget,
        configuration: GeminiTransportConfiguration,
        continuation: AsyncThrowingStream<GeminiTransportEvent, any Error>.Continuation,
        authorizeTrust: @escaping GeminiTransport.TrustAuthorization
    ) {
        self.target = target
        self.configuration = configuration
        self.continuation = continuation
        self.authorizeTrust = authorizeTrust
    }

    func start() {
        resetTimeout()
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] _, trustReference, complete in
                guard let self else {
                    complete(false)
                    return
                }
                let trust = sec_trust_copy_ref(trustReference).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let certificate = chain.first else {
                    complete(false)
                    return
                }

                let certificateDER = SecCertificateCopyData(certificate) as Data
                guard let fingerprint = try? SubjectPublicKeyFingerprint.sha256(
                    certificateDER: certificateDER
                ) else {
                    complete(false)
                    return
                }

                let dates = Self.certificateDates(certificate)
                let identity = PresentedServerIdentity(
                    endpoint: target.endpoint,
                    publicKeySHA256: fingerprint,
                    certificateNotBefore: dates.notBefore,
                    certificateNotAfter: dates.notAfter,
                    certificateDER: certificateDER
                )
                continuation.yield(.serverIdentity(identity))

                let completion = TrustVerificationCompletion(complete)
                Task {
                    completion.call(await authorizeTrust(identity, certificateDER))
                }
            },
            queue
        )

        // No transport-level proxy configuration. Major Tom's proxy support is a Gemini
        // proxy (see GeminiRequestTarget.init(proxying:through:)): the connection is an
        // ordinary Gemini connection to the proxy, and the request line carries the
        // http:// URL. An HTTP CONNECT tunnel, which is what used to be configured here,
        // is a different mechanism that no Gemini proxy speaks.
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            host: NWEndpoint.Host(target.endpoint.host),
            port: NWEndpoint.Port(rawValue: target.endpoint.port)!,
            using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }

        continuation.yield(.connecting(target.endpoint))
        connection.start(queue: queue)
    }

    func cancel() {
        connection?.cancel()
    }

    private func stateChanged(_ state: NWConnection.State) {
        guard let connection else { return }
        switch state {
        case .ready:
            resetTimeout()
            connection.send(content: target.requestData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    finish(throwing: GeminiTransportError.connectionFailed(error.localizedDescription))
                } else {
                    receiveNextChunk()
                }
            })
        case .failed(let error), .waiting(let error):
            finish(throwing: GeminiTransportError.connectionFailed(error.localizedDescription))
        case .cancelled:
            finish()
        default:
            break
        }
    }

    private func receiveNextChunk() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                resetTimeout()
                receivedByteCount += data.count
                guard receivedByteCount <= configuration.maximumResponseByteCount else {
                    finish(throwing: GeminiTransportError.responseTooLarge(
                        limit: configuration.maximumResponseByteCount
                    ))
                    return
                }
                do {
                    for event in try responseDecoder.receive(data) {
                        switch event {
                        case .header(let header): continuation.yield(.responseHeader(header))
                        case .body(let bytes): continuation.yield(.body(bytes))
                        }
                    }
                } catch let protocolError as GeminiProtocolError {
                    finish(throwing: GeminiTransportError.responseFailed(protocolError))
                    return
                } catch {
                    finish(throwing: error)
                    return
                }
            }

            if let error {
                finish(throwing: GeminiTransportError.connectionFailed(error.localizedDescription))
            } else if isComplete {
                do {
                    try responseDecoder.finish()
                    continuation.yield(.completed)
                    finish()
                } catch let protocolError as GeminiProtocolError {
                    finish(throwing: GeminiTransportError.responseFailed(protocolError))
                } catch {
                    finish(throwing: error)
                }
            } else {
                receiveNextChunk()
            }
        }
    }

    private func finish(throwing error: (any Error)? = nil) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func resetTimeout() {
        timeoutTask?.cancel()
        let timeout = configuration.idleTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                self?.finish(throwing: GeminiTransportError.timedOut)
            }
        }
    }

    private static func certificateDates(_ certificate: SecCertificate) -> (
        notBefore: Date?,
        notAfter: Date?
    ) {
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any] else {
            return (nil, nil)
        }

        func date(for key: CFString) -> Date? {
            guard let property = values[key] as? [CFString: Any] else { return nil }
            return property[kSecPropertyKeyValue] as? Date
        }

        return (
            date(for: kSecOIDX509V1ValidityNotBefore),
            date(for: kSecOIDX509V1ValidityNotAfter)
        )
    }
}

private final class TrustVerificationCompletion: @unchecked Sendable {
    private let callback: (Bool) -> Void

    init(_ callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }

    func call(_ isAllowed: Bool) {
        callback(isAllowed)
    }
}
