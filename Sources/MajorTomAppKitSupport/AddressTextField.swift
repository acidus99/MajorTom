import AppKit

/// Address editing needs a selected completion suffix, which SwiftUI's field does
/// not expose through its native field editor. All ordinary editing stays AppKit's.
public final class AddressTextField: NSTextField {
    public var focusChanged: ((Bool) -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusChanged?(true) }
        return became
    }
}
