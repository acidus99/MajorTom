import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiTransportIntegrationTests: XCTestCase {
    func testLiveGeminiTransportStreamsGemiDev() async throws {
        guard ProcessInfo.processInfo.environment["MAJOR_TOM_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set MAJOR_TOM_LIVE_TEST=1 to run live Gemini integration tests.")
        }

        let target = try GeminiRequestTarget("gemini://gemi.dev/")
        var identity: PresentedServerIdentity?
        var header: GeminiResponseHeader?
        var body = Data()
        var completed = false

        for try await event in GeminiTransport().events(for: target, authorizeTrust: { _, _ in true }) {
            switch event {
            case .connecting:
                break
            case .serverIdentity(let value):
                identity = value
            case .responseHeader(let value):
                header = value
            case .body(let chunk):
                body.append(chunk)
            case .completed:
                completed = true
            }
        }

        XCTAssertEqual(identity?.endpoint, target.endpoint)
        XCTAssertEqual(identity?.publicKeySHA256.count, 64)
        XCTAssertEqual(header?.status, 20)
        XCTAssertTrue(header?.meta.hasPrefix("text/gemini") == true)
        XCTAssertFalse(body.isEmpty)
        XCTAssertTrue(completed)
    }
}
