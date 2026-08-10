import AppKit
import MajorTomAppKitSupport
import XCTest

@available(macOS 26.0, *)
@MainActor
final class NativeTabHitTestingTests: XCTestCase {
    func testOnlyNativeTabButtonsAreRecognizedAsTabDragSources() throws {
        _ = NSApplication.shared
        let first = makeWindow(title: "First")
        let second = makeWindow(title: "Second")
        defer {
            first.tabGroup?.removeWindow(second)
            first.orderOut(nil)
            second.orderOut(nil)
        }

        first.addTabbedWindow(second, ordered: .above)
        first.makeKeyAndOrderFront(nil)
        first.contentView?.superview?.layoutSubtreeIfNeeded()
        first.displayIfNeeded()

        let frameView = try XCTUnwrap(first.contentView?.superview)
        let tabButton = try XCTUnwrap(firstDescendant(named: "NSTabButton", in: frameView))
        let tabCenterInWindow = tabButton.convert(
            NSPoint(x: tabButton.bounds.midX, y: tabButton.bounds.midY),
            to: nil
        )
        let tabCenterOnScreen = first.convertPoint(toScreen: tabCenterInWindow)
        XCTAssertTrue(NativeTabHitTesting.isOnTabButton(
            screenPoint: tabCenterOnScreen,
            in: first
        ))

        let contentCenterInWindow = first.contentView!.convert(
            NSPoint(x: first.contentView!.bounds.midX, y: first.contentView!.bounds.midY),
            to: nil
        )
        let contentCenterOnScreen = first.convertPoint(toScreen: contentCenterInWindow)
        XCTAssertFalse(NativeTabHitTesting.isOnTabButton(
            screenPoint: contentCenterOnScreen,
            in: first
        ))
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.tabbingIdentifier = "com.acidus.majortom.native-tab-test"
        window.tabbingMode = .preferred
        return window
    }

    private func firstDescendant(named className: String, in root: NSView) -> NSView? {
        if NSStringFromClass(type(of: root)).hasSuffix(className) { return root }
        for child in root.subviews {
            if let match = firstDescendant(named: className, in: child) { return match }
        }
        return nil
    }
}
