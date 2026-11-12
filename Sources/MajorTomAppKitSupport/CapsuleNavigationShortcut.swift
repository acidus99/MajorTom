import AppKit

public enum CapsuleNavigationShortcut: Equatable, Sendable {
    case upOneLevel
    case capsuleRoot

    public init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard keyCode == 126 else { return nil } // Up Arrow
        // Arrow events also carry Function/Numeric Pad flags; Caps Lock must not
        // change the command. Only the four shortcut modifiers determine routing.
        switch modifiers.intersection([.command, .option, .shift, .control]) {
        case [.command, .option]: self = .upOneLevel
        case [.command, .option, .shift]: self = .capsuleRoot
        default: return nil
        }
    }
}
