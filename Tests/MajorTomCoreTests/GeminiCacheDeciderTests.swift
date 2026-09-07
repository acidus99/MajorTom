import XCTest
@testable import MajorTomCore

final class GeminiCacheDeciderTests: XCTestCase {
    func testCachesSuccessfulGeminiImagesForOneDay() throws {
        let target = try GeminiRequestTarget("gemini://example.com/image.png")
        let response = makeResponse(url: target.url, status: 20, mimeType: "image/png")

        XCTAssertEqual(
            GeminiCacheDecider().decision(for: target, response: response),
            .store(resourceType: .image, lifetime: 24 * 60 * 60)
        )
    }

    func testDoesNotCacheNonImageSuccess() throws {
        let target = try GeminiRequestTarget("gemini://example.com/page.gmi")
        let response = makeResponse(url: target.url, status: 20, mimeType: "text/gemini")

        XCTAssertEqual(
            GeminiCacheDecider().decision(for: target, response: response),
            .doNotStore
        )
    }

    func testDoesNotCacheImageMIMEOnFailureOrRedirect() throws {
        let target = try GeminiRequestTarget("gemini://example.com/image.png")

        for status in [31, 40, 51, 60] {
            XCTAssertEqual(
                GeminiCacheDecider().decision(
                    for: target,
                    response: makeResponse(url: target.url, status: status, mimeType: "image/png")
                ),
                .doNotStore
            )
        }
    }

    func testDoesNotCacheResourcesFetchedThroughGeminiProxy() throws {
        let target = try GeminiRequestTarget(
            proxying: URL(string: "https://example.com/image.png")!,
            through: GeminiProxyConfiguration(host: "proxy.example", port: 1965)
        )

        XCTAssertEqual(
            GeminiCacheDecider().decision(
                for: target,
                response: makeResponse(url: target.url, status: 20, mimeType: "image/png")
            ),
            .doNotStore
        )
    }

    func testCachedGeminiResponseReplaysHeaderBodyAndCompletion() async throws {
        let response = makeResponse(
            url: URL(string: "gemini://example.com/image.png")!,
            status: 20,
            mimeType: "image/png",
            body: Data([1, 2, 3])
        )
        var events: [GeminiTransportEvent] = []

        for try await event in GeminiResponseReplay.events(for: response) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .responseHeader(try GeminiResponseHeader(status: 20, meta: "image/png")),
            .body(Data([1, 2, 3])),
            .completed
        ])
    }

    private func makeResponse(
        url: URL,
        status: Int,
        mimeType: String,
        body: Data = Data()
    ) -> ContentResponse {
        ContentResponse(
            url: url,
            status: status,
            meta: Data(mimeType.utf8),
            mimeType: mimeType,
            body: body,
            receivedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
