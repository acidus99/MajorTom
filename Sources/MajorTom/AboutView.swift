import AppKit
import MajorTomCore
import SwiftUI

/// Owns the single About window.
///
/// Built as an `NSWindow` around the SwiftUI view rather than as a `Window` scene so it
/// can be opened from the application delegate, which has no `openWindow` action, and so
/// it stays out of the Window menu and out of session restoration.
///
/// State lives here rather than on the delegate so the notification observer that calls
/// `show()` captures nothing: sending a non-`Sendable` delegate into that closure is a
/// data race the compiler correctly refuses.
@MainActor
enum AboutWindowPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let created = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        created.title = "About Major Tom"
        created.styleMask = [.titled, .closable]
        // The window outlives this call; without this it is deallocated on close and the
        // next About would reach a freed object.
        created.isReleasedWhenClosed = false
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
    }
}

/// The About panel, following the legacy app's layout: a large app icon, the name, the
/// version, and the copyright, centred in a fixed-width column.
///
/// The version is shown in the commit-date scheme rather than a hand-maintained semantic
/// version — `2026.8.4 (231)` — with the full build identity beneath it. That second line
/// is the one worth quoting in a bug report, so it is selectable and monospaced.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)

            Text("Major Tom")
                .font(.system(size: 28, weight: .semibold))

            VStack(spacing: 5) {
                Text("Version \(AppVersion.short) (\(AppVersion.build))")
                    .font(.system(size: 15))
                Text(AppVersion.buildInfo)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

            Text("A native macOS browser for Gemini.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Copyright \u{00A9} 2026 Major Tom\nAll rights reserved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 30)
        .frame(width: 420)
    }
}
