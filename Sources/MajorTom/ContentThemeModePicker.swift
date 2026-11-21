import AppKit
import MajorTomAppKitSupport
import MajorTomCore
import SwiftUI

/// Native radio buttons stay separate from their subordinate controls in the
/// accessibility tree. SwiftUI owns all layout; no nested hosting views are needed.
struct ContentThemeModeButton: NSViewRepresentable {
    let mode: ContentThemeSelection
    let title: String
    let explanation: String
    @Binding var selection: ContentThemeSelection
    let group: ContentThemeRadioGroup

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, mode: mode) }

    func makeNSView(context: Context) -> ContentThemeRadioButton {
        let button = ContentThemeRadioButton(title: title, target: context.coordinator, action: #selector(Coordinator.choose))
        button.setButtonType(.radio)
        button.setAccessibilityHelp(explanation)
        button.moveSelection = { group.move(from: mode) }
        if mode == .family { group.family = button }
        else { group.individual = button }
        return button
    }

    func updateNSView(_ view: ContentThemeRadioButton, context: Context) {
        context.coordinator.selection = $selection
        view.state = selection == mode ? .on : .off
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ContentThemeRadioButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<ContentThemeSelection>
        let mode: ContentThemeSelection
        init(selection: Binding<ContentThemeSelection>, mode: ContentThemeSelection) {
            self.selection = selection
            self.mode = mode
        }
        @objc func choose() { selection.wrappedValue = mode }
    }
}
