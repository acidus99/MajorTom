import AppKit

@available(macOS 26.0, *)
@MainActor
public enum NativeTabHitTesting {
    public static func isOnTabButton(screenPoint: NSPoint, in window: NSWindow) -> Bool {
        guard window.tabbedWindows != nil,
              let frameView = window.contentView?.superview else { return false }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return descendants(of: frameView).contains { view in
            guard NSStringFromClass(type(of: view)).hasSuffix("NSTabButton") else {
                return false
            }
            return view.bounds.contains(view.convert(windowPoint, from: nil))
        }
    }

    private static func descendants(of root: NSView) -> [NSView] {
        var result = [root]
        for child in root.subviews {
            result.append(contentsOf: descendants(of: child))
        }
        return result
    }
}
