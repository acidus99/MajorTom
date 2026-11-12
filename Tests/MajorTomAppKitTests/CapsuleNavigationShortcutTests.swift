import AppKit
import MajorTomAppKitSupport
import XCTest

final class CapsuleNavigationShortcutTests: XCTestCase {
    // Prevent the broken Option-Up binding from swallowing text-system keys or
    // losing navigation to the content responder; only Command-Option-Up navigates.
    func testExplicitCapsuleNavigationShortcuts() {
        XCTAssertEqual(CapsuleNavigationShortcut(keyCode: 126, modifiers: [.command, .option]), .upOneLevel)
        XCTAssertEqual(CapsuleNavigationShortcut(keyCode: 126, modifiers: [.command, .option, .shift]), .capsuleRoot)
        for modifiers: NSEvent.ModifierFlags in [[], .option, [.option, .shift], [.command, .control, .option]] {
            XCTAssertNil(CapsuleNavigationShortcut(keyCode: 126, modifiers: modifiers))
        }
    }

    // Regression: Command-Up/Down must keep scrolling, including selection variants.
    func testDocumentScrollingKeysAreNotClaimed() {
        for keyCode: UInt16 in [125, 126] {
            for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
                XCTAssertNil(CapsuleNavigationShortcut(keyCode: keyCode, modifiers: modifiers))
            }
        }
        for keyCode: UInt16 in [123, 124, 125] {
            XCTAssertNil(CapsuleNavigationShortcut(keyCode: keyCode, modifiers: [.command, .option]))
        }
    }

    func testArrowEventFlagsAndCapsLockDoNotChangeNavigation() {
        let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad, .capsLock]
        XCTAssertEqual(
            CapsuleNavigationShortcut(keyCode: 126, modifiers: [.command, .option, arrowFlags]),
            .upOneLevel
        )
        XCTAssertEqual(
            CapsuleNavigationShortcut(keyCode: 126, modifiers: [.command, .option, .shift, arrowFlags]),
            .capsuleRoot
        )
    }
}
