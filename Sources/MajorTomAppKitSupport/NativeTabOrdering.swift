import AppKit

@available(macOS 26.0, *)
@MainActor
public enum NativeTabOrdering {
    /// `addTabbedWindow(_:ordered:)` inserts after its receiver. Choosing the final peer
    /// as the receiver therefore appends a new tab without disturbing the current order.
    public static func endInsertionAnchor(for selectedWindow: NSWindow) -> NSWindow {
        selectedWindow.tabGroup?.windows.last ?? selectedWindow
    }
}
