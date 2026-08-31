import AppKit
import Combine

/// One application-wide monitor for modifier-key changes.
///
/// Each `BrowserModel` used to install its own `.flagsChanged` monitor in `init`. The
/// model has no `deinit`, and nothing else called `NSEvent.removeMonitor`, so closing a
/// tab leaked the monitor: every later press or release of Command, Shift, Option or
/// Control walked one dead closure per tab that had ever been opened.
///
/// `installCommandKeyMonitor` records the same lesson for key-down events — "a per-view
/// monitor was installed once per open window, so every window reacted to one key press".
/// Publishing from a single monitor lets each tab hold an ordinary Combine subscription
/// that is released with the model, so nothing has to be torn down by hand.
@MainActor
final class ModifierFlagsMonitor {
    static let shared = ModifierFlagsMonitor()

    let flagsDidChange = PassthroughSubject<NSEvent.ModifierFlags, Never>()

    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsDidChange.send(event.modifierFlags)
            return event
        }
    }
}
