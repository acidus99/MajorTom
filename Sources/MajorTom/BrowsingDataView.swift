import Combine
import MajorTomCore
import OSLog
import SwiftUI

@MainActor
final class BrowsingDataController: ObservableObject {
    static let shared = BrowsingDataController()
    @Published var action: BrowsingDataAction = .clearBrowsingData
    @Published private(set) var isClearing = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(controller.action.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(controller.action == .clearBrowsingData
                 ? "Remove browsing history, Back/Forward visits, input drafts, and cached pages, images, and favicons from this Mac."
                 : "Remove cached pages, images, and favicons from this Mac. Browsing history, Back/Forward destinations, and input drafts are kept.")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Time Range", selection: $range) {
                ForEach(BrowsingDataTimeRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.menu)
            .help(controller.action == .clearBrowsingData
                  ? "Clear visits and draft edits from this period, and content fetched or used during it."
                  : "Clear content fetched or used during this period.")
            Text("All open windows and tabs stay open. Their current pages and reading positions are kept, and their addresses can restore next launch. Requests in progress stop. Content is fetched again when needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Task {
                        do {
                            try await controller.clear(action, range: range)
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
            range = .last24Hours
            errorMessage = nil
        }
        .onChange(of: controller.action) {
            range = .last24Hours
            errorMessage = nil
        }
    }
}
