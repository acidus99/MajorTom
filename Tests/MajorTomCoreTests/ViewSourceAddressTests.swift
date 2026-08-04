import Foundation
import XCTest
@testable import MajorTomCore

final class ViewSourceURLTests: XCTestCase {
    func testWrapPrefixesTheResource() {
        let wrapped = ViewSourceURL.wrap(URL(string: "gemini://example.com/a.gmi")!)
        XCTAssertEqual(wrapped?.absoluteString, "view-source:gemini://example.com/a.gmi")
    }

    func testWrappingRefusesToNest() {
        let once = ViewSourceURL.wrap(URL(string: "gemini://example.com/a.gmi")!)!
        XCTAssertNil(ViewSourceURL.wrap(once))
    }

    func testUnwrapReturnsTheResource() {
        let url = URL(string: "view-source:gemini://example.com/a.gmi")!
        XCTAssertEqual(ViewSourceURL.unwrap(url)?.absoluteString, "gemini://example.com/a.gmi")
    }

    func testUnwrapIgnoresOrdinaryURLs() {
        XCTAssertNil(ViewSourceURL.unwrap(URL(string: "gemini://example.com/")!))
    }

    func testIsViewSourceIgnoresSchemeCase() {
        XCTAssertTrue(ViewSourceURL.isViewSource(URL(string: "VIEW-SOURCE:gemini://example.com/")!))
    }

    func testRoundTrip() {
        let resource = URL(string: "gemini://example.com/dir/page.gmi?q=1")!
        let wrapped = ViewSourceURL.wrap(resource)!
        XCTAssertEqual(ViewSourceURL.unwrap(wrapped), resource)
    }

    func testUnwrapTextStripsThePrefix() {
        XCTAssertEqual(
            ViewSourceURL.unwrap(text: "view-source:gemini://example.com/"),
            "gemini://example.com/"
        )
    }

    func testUnwrapTextIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(
            ViewSourceURL.unwrap(text: "  View-Source: gemini://example.com/  "),
            "gemini://example.com/"
        )
    }

    func testUnwrapTextReturnsNilForOtherAddresses() {
        XCTAssertNil(ViewSourceURL.unwrap(text: "gemini://example.com/"))
        XCTAssertNil(ViewSourceURL.unwrap(text: "kennedy search terms"))
    }

    func testUnwrapTextOfPrefixAloneIsEmptyRatherThanNil() {
        XCTAssertEqual(ViewSourceURL.unwrap(text: "view-source:"), "")
    }
}

final class ViewSourceAddressInputTests: XCTestCase {
    private let interpreter = AddressInputInterpreter()

    /// The regression this feature fixes: "://" inside the wrapped URL used to make the
    /// interpreter classify the whole thing as an external address, which the model then
    /// refused as an unsupported scheme.
    func testViewSourceAddressIsRecognised() throws {
        guard case .viewSource(let target) = try interpreter.interpret("view-source:gemini://example.com/a.gmi") else {
            return XCTFail("expected a viewSource result")
        }
        XCTAssertEqual(target.url.absoluteString, "gemini://example.com/a.gmi")
    }

    func testViewSourceAddressAcceptsMixedCasePrefix() throws {
        guard case .viewSource = try interpreter.interpret("View-Source:gemini://example.com/") else {
            return XCTFail("expected a viewSource result")
        }
    }

    /// The wrapped URL is normalised like any other request target.
    func testWrappedURLIsNormalised() throws {
        guard case .viewSource(let target) = try interpreter.interpret("view-source:gemini://EXAMPLE.com") else {
            return XCTFail("expected a viewSource result")
        }
        XCTAssertEqual(target.url.absoluteString, "gemini://example.com/")
        XCTAssertEqual(target.endpoint.port, 1_965)
    }

    func testViewSourceOfANonGeminiResourceIsRejected() {
        XCTAssertThrowsError(try interpreter.interpret("view-source:https://example.com/")) { error in
            XCTAssertEqual(error as? AddressInputError, .invalidGeminiURL)
        }
    }

    func testViewSourceWithNothingWrappedIsRejected() {
        XCTAssertThrowsError(try interpreter.interpret("view-source:")) { error in
            XCTAssertEqual(error as? AddressInputError, .invalidGeminiURL)
        }
    }

    /// Ordinary addresses must keep their existing classification.
    func testOtherAddressesAreUnaffected() throws {
        guard case .gemini = try interpreter.interpret("gemini://example.com/") else {
            return XCTFail("expected gemini")
        }
        guard case .external = try interpreter.interpret("https://example.com/") else {
            return XCTFail("expected external")
        }
        guard case .gemini(let search) = try interpreter.interpret("some search words") else {
            return XCTFail("expected a search")
        }
        XCTAssertTrue(search.url.absoluteString.hasPrefix("gemini://kennedy.gemi.dev/search?"))
    }
}
