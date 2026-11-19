import AppKit
import XCTest
@testable import MajorTomAppKitSupport

final class AddressSuggestionsViewTests: XCTestCase {
    @MainActor
    func testRowAndSelectionChangesKeepPanelFrameUnderAppKitControl() {
        // Prevents the omnibar's November 2026 crash: hosted SwiftUI rows repeatedly
        // invalidated NSWindow constraints during its display/layout cycle.
        let panel = NSPanel(contentRect: NSRect(x: 30, y: 30, width: 500, height: 312),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let content = AddressSuggestionsView(frame: NSRect(x: 0, y: 0, width: 500, height: 312))
        panel.contentView = content
        for count in [1, 8, 2, 6, 3, 8, 1, 6] {
            let size = NSSize(width: 500, height: CGFloat(count) * 50 + 12)
            panel.setContentSize(size)
            content.setItems((0..<count).map { index in
                AddressSuggestionItem(title: "Destination \(index)", detail: "gemini://example.org/\(index)",
                                      symbol: "clock", isSelected: index == count - 1, menu: nil, activate: {})
            })
            content.updateConstraintsForSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            XCTAssertEqual(content.frame.size, size)
            XCTAssertEqual(content.subviews.count, count)
            XCTAssertTrue(content.subviews.allSatisfy { content.bounds.contains($0.frame) })
        }
        panel.close()
    }

    @MainActor
    func testSuggestionUsesAnAccessibleNativeButtonWithoutTakingEditorFocus() throws {
        var activated = false
        let content = AddressSuggestionsView(frame: NSRect(x: 0, y: 0, width: 500, height: 62))
        content.setItems([AddressSuggestionItem(title: "Gardening", detail: "Bookmark · gemini://example.org/",
                                               symbol: "star", isSelected: true, menu: nil, activate: { activated = true })])
        let button = try XCTUnwrap(content.subviews.first as? NSButton)
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertTrue(button.accessibilityLabel()?.contains("Gardening") == true)
        button.performClick(nil)
        XCTAssertTrue(activated)
    }
}
