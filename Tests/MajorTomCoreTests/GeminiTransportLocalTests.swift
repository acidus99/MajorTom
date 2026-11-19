import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiTransportLocalTests: XCTestCase {
    @MainActor
    func testTrustDecisionCanOutlastNetworkIdleTimeoutThenStreamExactBytes() async throws {
        let server = try LocalTLSServer()
        defer { server.stop() }
        let entered = expectation(description: "TLS trust decision entered")
        let premature = expectation(description: "Transport must not time out while awaiting the reader")
        premature.isInverted = true
        let decision = AsyncStream<Bool>.makeStream()
        defer { decision.continuation.finish() }
        let phase = DecisionPhase()
        let reading = Task {
            do {
                let bytes = try await Self.read(server.target) { _, _ in
                    entered.fulfill()
                    for await answer in decision.stream { return answer }
                    return false
                }
                if phase.isPending { premature.fulfill() }
                return bytes
            } catch {
                if phase.isPending { premature.fulfill() }
                throw error
            }
        }
        defer { reading.cancel() }
        await fulfillment(of: [entered], timeout: 3)
        // Exercise Network.framework's actual timer: three full idle periods pass.
        await fulfillment(of: [premature], timeout: 0.75)
        phase.isPending = false
        decision.continuation.yield(true)
        decision.continuation.finish()
        let body = try await reading.value
        XCTAssertEqual(body, LocalTLSServer.body)
    }

    func testDecliningActualTLSVerificationReportsTrustDeclinedWithoutResponseBytes() async throws {
        let server = try LocalTLSServer()
        defer { server.stop() }
        do {
            _ = try await Self.read(server.target) { _, _ in false }
            XCTFail("Declining verification must refuse the connection")
        } catch GeminiTransportError.trustDeclined {}
    }

    @MainActor
    func testCancellingTransportWithdrawsPendingTLSAuthorization() async throws {
        let server = try LocalTLSServer()
        defer { server.stop() }
        let entered = expectation(description: "Verification waiting")
        let withdrawn = expectation(description: "Pending authorization cancelled")
        let decision = AsyncStream<Bool>.makeStream()
        decision.continuation.onTermination = { _ in withdrawn.fulfill() }
        defer { decision.continuation.finish() }
        let reading = Task {
            try await Self.read(server.target) { _, _ in
                entered.fulfill()
                for await answer in decision.stream { return answer }
                return false
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        reading.cancel()
        await fulfillment(of: [withdrawn], timeout: 3)
        _ = await reading.result
    }

    @MainActor
    func testPeerFailureWhileTrustIsPendingWithdrawsAuthorization() async throws {
        let server = try LocalTLSServer()
        defer { server.stop() }
        let entered = expectation(description: "Peer verification waiting")
        let withdrawn = expectation(description: "Failed peer authorization withdrawn")
        let finished = expectation(description: "Failed peer transport finished")
        let decision = AsyncStream<Bool>.makeStream()
        decision.continuation.onTermination = { _ in withdrawn.fulfill() }
        defer { decision.continuation.finish() }
        let reading = Task<GeminiTransportError?, Never> {
            defer { finished.fulfill() }
            do {
                _ = try await Self.read(server.target) { _, _ in
                    entered.fulfill()
                    for await answer in decision.stream { return answer }
                    return false
                }
                return nil
            } catch { return error as? GeminiTransportError }
        }
        defer { reading.cancel() }
        await fulfillment(of: [entered], timeout: 3)
        try server.abortConnection()
        let result = await XCTWaiter.fulfillment(of: [withdrawn, finished], timeout: 3)
        if result != .completed { reading.cancel() }
        XCTAssertEqual(result, .completed)
        let failure = await reading.value
        guard case .some(.connectionFailed(_)) = failure else {
            return XCTFail("A peer failure must remain a connection failure, rather than a trust refusal")
        }
    }

    private static func read(_ target: GeminiRequestTarget, authorize: @escaping GeminiTransport.TrustAuthorization) async throws -> Data {
        var body = Data()
        for try await event in GeminiTransport().events(for: target,
            configuration: GeminiTransportConfiguration(idleTimeout: .milliseconds(250)), authorizeTrust: authorize) {
            if case .body(let chunk) = event { body.append(chunk) }
        }
        return body
    }
}

@MainActor
private final class DecisionPhase { var isPending = true }

/// Ephemeral server material stays in a private temporary directory, never Keychain
/// or the repository. Only localhost is used; this is part of the ordinary suite.
private final class LocalTLSServer {
    static let body = Data("# Local TLS fixture\nExact raw response bytes.\r\n".utf8)
    let target: GeminiRequestTarget
    private let process: Process
    private let input: Pipe
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MajorTomTLS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = directory.appendingPathComponent("key.pem")
        let certificate = directory.appendingPathComponent("certificate.pem")
        process = Process()
        input = Pipe()
        do {
            let generator = Process()
            generator.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            generator.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                "-keyout", key.path, "-out", certificate.path, "-days", "1", "-subj", "/CN=fixture.invalid"]
            generator.standardOutput = FileHandle.nullDevice
            generator.standardError = FileHandle.nullDevice
            try generator.run()
            generator.waitUntilExit()
            guard generator.terminationStatus == 0 else { throw URLError(.cannotCreateFile) }
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", "-c", Self.script, certificate.path, key.path, Self.body.base64EncodedString()]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
            guard let port = UInt16(String(decoding: line, as: UTF8.self)) else { throw URLError(.cannotConnectToHost) }
            target = try GeminiRequestTarget("gemini://127.0.0.1:\(port)/fixture")
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func abortConnection() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("close\n".utf8))
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
    import base64, socket, ssl, sys, threading
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    print(listener.getsockname()[1], flush=True)
    shared = {}
    def serve():
        try:
            raw, _ = listener.accept()
            with context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False) as connection:
                shared['connection'] = connection
                connection.do_handshake()
                request = b''
                while not request.endswith(b'\r\n'):
                    chunk = connection.recv(1024)
                    if not chunk: return
                    request += chunk
                connection.sendall(b'20 text/gemini\r\n' + base64.b64decode(sys.argv[3]))
                connection.unwrap()
        except Exception:
            pass
    threading.Thread(target=serve, daemon=True).start()
    for command in sys.stdin:
        if command.strip() == 'close' and 'connection' in shared:
            connection = shared['connection']
            try: connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            connection.close()
    """#
}
