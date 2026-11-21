import AppKit
import MajorTomCore

@MainActor
public final class ContentThemeRadioGroup {
    public weak var family: NSButton?
    public weak var individual: NSButton?

    public init() {}

    public func move(from mode: ContentThemeSelection) {
        let next = mode == .family ? individual : family
        next?.window?.makeFirstResponder(next)
        next?.performClick(nil)
    }
}

public final class ContentThemeRadioButton: NSButton {
    public var moveSelection: (() -> Void)?
    public override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            moveSelection?()
        } else { super.keyDown(with: event) }
    }
}
