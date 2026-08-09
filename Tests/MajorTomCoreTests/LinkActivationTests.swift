import XCTest
@testable import MajorTomCore

final class LinkActivationTests: XCTestCase {
    func testPlainClickUsesCurrentTab() {
        XCTAssertEqual(activation(buttonNumber: 1), .currentTab)
    }

    func testKeyboardActivationUsesCurrentTab() {
        XCTAssertEqual(activation(buttonNumber: 0), .currentTab)
    }

    func testCommandClickOpensBackgroundTab() {
        XCTAssertEqual(activation(.command), .newBackgroundTab)
    }

    func testShiftCommandClickOpensForegroundTab() {
        XCTAssertEqual(activation([.shift, .command]), .newForegroundTab)
    }

    func testShiftClickOpensWindow() {
        XCTAssertEqual(activation(.shift), .newWindow)
    }

    func testOptionClickDownloads() {
        XCTAssertEqual(activation(.option), .download)
    }

    func testControlClickShowsContextMenu() {
        XCTAssertEqual(activation(.control), .contextMenu)
    }

    func testMiddleClickOpensBackgroundTab() {
        XCTAssertEqual(activation(buttonNumber: 2), .newBackgroundTab)
    }

    func testRightClickShowsContextMenu() {
        XCTAssertEqual(activation(buttonNumber: 3), .contextMenu)
    }

    func testControlOutranksOtherModifiers() {
        XCTAssertEqual(activation([.control, .option, .command, .shift]), .contextMenu)
    }

    func testOptionOutranksOpeningModifiers() {
        XCTAssertEqual(activation([.option, .command, .shift]), .download)
    }

    func testHoverTextUsesTheURLByDefault() {
        XCTAssertEqual(LinkHoverText.text(for: "gemini://example.com/", modifiers: []), "gemini://example.com/")
    }

    func testHoverTextDescribesEachModifierAction() {
        let url = "gemini://example.com/"
        XCTAssertEqual(LinkHoverText.text(for: url, modifiers: .command), "Open \"\(url)\" in new background tab")
        XCTAssertEqual(LinkHoverText.text(for: url, modifiers: [.command, .shift]), "Open \"\(url)\" in new tab")
        XCTAssertEqual(LinkHoverText.text(for: url, modifiers: .shift), "Open \"\(url)\" in new window")
        XCTAssertEqual(LinkHoverText.text(for: url, modifiers: .option), "Download \"\(url)\"")
        XCTAssertEqual(LinkHoverText.text(for: url, modifiers: .control), "Display a menu for \"\(url)\"")
    }

    private func activation(
        _ modifiers: LinkModifierKeys = [],
        buttonNumber: Int = 0
    ) -> LinkActivation {
        LinkActivationPolicy.activation(buttonNumber: buttonNumber, modifiers: modifiers)
    }
}
