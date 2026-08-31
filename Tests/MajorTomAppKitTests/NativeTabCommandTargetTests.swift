import AppKit
import MajorTomAppKitSupport
import XCTest

@available(macOS 26.0, *)
@MainActor
final class NativeTabCommandTargetTests: XCTestCase {
    func testOnlySelectedWindowInNativeTabGroupHandlesCommands() {
        _ = NSApplication.shared
        let first = makeWindow(title: "First")
        let second = makeWindow(title: "Second")
        defer {
            first.tabGroup?.removeWindow(second)
            first.orderOut(nil)
            second.orderOut(nil)
        }

        first.addTabbedWindow(second, ordered: .above)
        guard let tabGroup = first.tabGroup else {
            return XCTFail("Expected AppKit to create a native tab group")
        }

        tabGroup.selectedWindow = first
        XCTAssertTrue(NativeTabCommandTarget.isSelectedTab(first, keyWindow: first))
        XCTAssertFalse(NativeTabCommandTarget.isSelectedTab(second, keyWindow: first))

        tabGroup.selectedWindow = second
        XCTAssertTrue(NativeTabCommandTarget.isSelectedTab(second, keyWindow: second))
        XCTAssertFalse(NativeTabCommandTarget.isSelectedTab(first, keyWindow: second))
    }

    func testWindowIsNotTargetWhenAppKitReportsItKeyButAnotherNativeTabIsSelected() {
        _ = NSApplication.shared
        let first = makeWindow(title: "First")
        let second = makeWindow(title: "Second")
        defer {
            first.tabGroup?.removeWindow(second)
            first.orderOut(nil)
            second.orderOut(nil)
        }

        first.addTabbedWindow(second, ordered: .above)
        guard let tabGroup = first.tabGroup else {
            return XCTFail("Expected AppKit to create a native tab group")
        }
        tabGroup.selectedWindow = second

        XCTAssertFalse(NativeTabCommandTarget.isSelectedTab(first, keyWindow: first))
    }

    func testAddingRestoredTabsInSavedOrderKeepsVisualOrder() {
        _ = NSApplication.shared
        let first = makeWindow(title: "A")
        let second = makeWindow(title: "B")
        let third = makeWindow(title: "C")
        defer {
            first.tabGroup?.removeWindow(second)
            first.tabGroup?.removeWindow(third)
            [first, second, third].forEach { $0.orderOut(nil) }
        }

        first.addTabbedWindow(third, ordered: .above)
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = third
        third.makeKeyAndOrderFront(nil)

        XCTAssertEqual(first.tabGroup?.windows.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(first.tabGroup?.windows.map { $0.tab.title }, ["Tab A", "Tab B", "Tab C"])
        XCTAssertTrue(first.tabGroup?.selectedWindow === third)
    }

    func testEndInsertionAnchorIsTheRightmostTab() {
        _ = NSApplication.shared
        let first = makeWindow(title: "A")
        let second = makeWindow(title: "B")
        let third = makeWindow(title: "C")
        defer {
            first.tabGroup?.removeWindow(second)
            first.tabGroup?.removeWindow(third)
            [first, second, third].forEach { $0.orderOut(nil) }
        }

        first.addTabbedWindow(third, ordered: .above)
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = second

        XCTAssertTrue(NativeTabOrdering.endInsertionAnchor(for: second) === third)
    }

    func testEndInsertionAnchorForSingleWindowIsThatWindow() {
        _ = NSApplication.shared
        let window = makeWindow(title: "Only")
        defer { window.orderOut(nil) }

        XCTAssertTrue(NativeTabOrdering.endInsertionAnchor(for: window) === window)
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.tab.title = "Tab \(title)"
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "com.acidus.majortom.command-target-test"
        window.tabbingMode = .preferred
        return window
    }
}
