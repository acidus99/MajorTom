import AppKit

@available(macOS 26.0, *)
@MainActor
public enum NativeTabCommandTarget {
    public static func isSelectedTab(
        _ window: NSWindow?,
        keyWindow: NSWindow?
    ) -> Bool {
        guard let window, window === keyWindow else { return false }
        return window.tabGroup?.selectedWindow.map { $0 === window } ?? true
    }
}
