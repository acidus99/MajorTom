import Foundation

/// Device-independent modifiers that affect how a link is opened.
public struct LinkModifierKeys: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = LinkModifierKeys(rawValue: 1 << 0)
    public static let shift = LinkModifierKeys(rawValue: 1 << 1)
    public static let option = LinkModifierKeys(rawValue: 1 << 2)
    public static let control = LinkModifierKeys(rawValue: 1 << 3)
}

public enum LinkActivation: Equatable, Sendable {
    case currentTab
    case newBackgroundTab
    case newForegroundTab
    case newWindow
    case download
    case contextMenu
}

/// Resolves mouse buttons and modifiers before WebKit is allowed to navigate.
public enum LinkActivationPolicy {
    /// WebKit reports 0 when no mouse caused the navigation, then numbers the left,
    /// middle and right buttons 1, 2 and 3 respectively.
    public static func activation(
        buttonNumber: Int,
        modifiers: LinkModifierKeys
    ) -> LinkActivation {
        // Context-menu intent outranks every opening or download modifier.
        if buttonNumber == 3 || modifiers.contains(.control) { return .contextMenu }
        if buttonNumber == 2 { return .newBackgroundTab }
        if modifiers.contains(.option) { return .download }
        if modifiers.contains(.command) {
            return modifiers.contains(.shift) ? .newForegroundTab : .newBackgroundTab
        }
        if modifiers.contains(.shift) { return .newWindow }
        return .currentTab
    }
}

public enum LinkHoverText {
    public static func text(for url: String, modifiers: LinkModifierKeys) -> String {
        if modifiers.contains(.control) {
            return "Display a menu for \"\(url)\""
        }
        if modifiers.contains(.option) {
            return "Download \"\(url)\""
        }
        if modifiers.contains(.command) && modifiers.contains(.shift) {
            return "Open \"\(url)\" in new tab"
        }
        if modifiers.contains(.command) {
            return "Open \"\(url)\" in new background tab"
        }
        if modifiers.contains(.shift) {
            return "Open \"\(url)\" in new window"
        }
        return url
    }
}
