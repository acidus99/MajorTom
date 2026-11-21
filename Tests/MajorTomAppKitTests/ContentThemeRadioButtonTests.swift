import AppKit
import MajorTomCore
import XCTest
@testable import MajorTomAppKitSupport

final class ContentThemeRadioButtonTests: XCTestCase {
    @MainActor
    func testArrowKeysSelectTheOtherNativeRadioButton() throws {
        // Interleaved subordinate controls must not break native radio-group keyboard navigation.
        let target = SelectionTarget()
        let family = ContentThemeRadioButton(title: "Use theme family", target: target, action: #selector(SelectionTarget.chooseFamily))
        let individual = ContentThemeRadioButton(title: "Choose individual themes", target: target, action: #selector(SelectionTarget.chooseIndividual))
        for button in [family, individual] { button.setButtonType(.radio) }
        let group = ContentThemeRadioGroup()
        group.family = family
        group.individual = individual
        family.moveSelection = { group.move(from: .family) }
        individual.moveSelection = { group.move(from: .individual) }
        for key: UInt16 in [123, 124, 125, 126] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                      isARepeat: false, keyCode: key))
            family.keyDown(with: event)
            XCTAssertEqual(target.selection, .individual)
            individual.keyDown(with: event)
            XCTAssertEqual(target.selection, .family)
        }
    }
}

@MainActor
private final class SelectionTarget: NSObject {
    var selection = ContentThemeSelection.family
    @objc func chooseFamily() { selection = .family }
    @objc func chooseIndividual() { selection = .individual }
}
