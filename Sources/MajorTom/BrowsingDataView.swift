import Combine
import MajorTomCore
import OSLog
import SwiftUI

@MainActor
final class BrowsingDataController: ObservableObject {
    static let shared = BrowsingDataController()
    @Published private(set) var action: BrowsingDataAction = .clearBrowsingData
    @Published private(set) var requestedRange: BrowsingDataTimeRange?
    @Published private(set) var isClearing = false

    /// Settings chooses the range before confirmation; menu commands choose it in
    /// the shared confirmation window. Capture the choice separately from the rows.
    func present(_ action: BrowsingDataAction, range: BrowsingDataTimeRange? = nil) {
        guard !isClearing else { return }
        requestedRange = range
        self.action = action
    }

    func clear(_ action: BrowsingDataAction, range: BrowsingDataTimeRange) async throws {
        guard !isClearing else { return }
        isClearing = true
        let cutoff = range.cutoff(at: Date())
        let browsers = NativeTabCoordinator.shared.browsingDataModels
        for browser in browsers { browser.prepareForClearing(action, since: cutoff) }
        defer {
            for browser in browsers { browser.finishClearing() }
            isClearing = false
        }
        // Increment the cache generation before draining writes. Requests that were
        // already fetching cannot repopulate the cache after the deletion boundary.
        try await SharedContentCache.shared?.removeResponses(since: cutoff)
        for browser in browsers { await browser.drainWritesForClearing() }
        // Save sanitized live metadata first, so the persistent content selection sees
        // recent uses of older responses and the final cursor positions.
        if !browsers.isEmpty { try NativeTabCoordinator.shared.persistSessionAfterClearing() }
        try SessionRestorationStore.shared.clearBrowsingData(action, since: cutoff)
        if action == .clearBrowsingData {
            try BrowsingHistoryStore.shared.clear(since: cutoff)
            try GeminiInputDraftStore.shared.clear(since: cutoff)
        }
    }
}

struct BrowsingDataView: View {
    @ObservedObject private var controller = BrowsingDataController.shared
    @ObservedObject private var settings = BrowserSettingsStore.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var range: BrowsingDataTimeRange = .last24Hours
    @State private var errorMessage: String?
    @FocusState private var dialogHasFocus: Bool

    private var preferredColorScheme: ColorScheme? {
        switch settings.preferences.applicationAppearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var confirmationMessage: String {
        let selected = controller.requestedRange ?? range
        if controller.action == .clearBrowsingData {
            let period = selected == .last24Hours ? "from the last 24 hours" : "for all time"
            return "Clear this Mac’s browsing history, input drafts, and cached content \(period)."
        }
        let period = selected == .last24Hours ? "fetched or used in the last 24 hours" : "for all time"
        return "Clear cached pages, images, and favicons \(period) from this Mac."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(controller.action.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(confirmationMessage)
                .fixedSize(horizontal: false, vertical: true)
            if controller.requestedRange == nil {
                Picker("Time Range", selection: $range) {
                    ForEach(BrowsingDataTimeRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.menu)
                .help(controller.action == .clearBrowsingData
                      ? "Clear visits and draft edits from this period, and content fetched or used during it."
                      : "Clear content fetched or used during this period.")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityLabel("Clearing failed. \(errorMessage)")
            }
            HStack {
                if controller.isClearing {
                    ProgressView().controlSize(.small)
                    Text("Clearing…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismissWindow(id: "browsing-data") }
                    .keyboardShortcut(.defaultAction)
                Button(controller.action.title, role: .destructive) {
                    let action = controller.action
                    let selectedRange = controller.requestedRange ?? range
                    Task {
                        do {
                            try await controller.clear(action, range: selectedRange)
                            dismissWindow(id: "browsing-data")
                        } catch {
                            Logger(subsystem: "dev.gemi.major-tom", category: "BrowsingData")
                                .error("Clearing browsing data failed: \(String(describing: error), privacy: .private)")
                            errorMessage = "Some data could not be cleared. Try again."
                        }
                    }
                }
            }
        }
        .padding(24)
        .preferredColorScheme(preferredColorScheme)
        .frame(width: 460)
        .disabled(controller.isClearing)
        .focusable()
        .focusEffectDisabled()
        .focused($dialogHasFocus)
        .onExitCommand {
            if !controller.isClearing { dismissWindow(id: "browsing-data") }
        }
        .onAppear {
            dialogHasFocus = true
            range = controller.requestedRange ?? .last24Hours
            errorMessage = nil
        }
        .onChange(of: controller.requestedRange) {
            range = controller.requestedRange ?? .last24Hours
            errorMessage = nil
        }
        .onChange(of: controller.action) {
            range = controller.requestedRange ?? .last24Hours
            errorMessage = nil
        }
    }
}
