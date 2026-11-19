import Combine
import MajorTomCore
import OSLog
import SwiftUI

@MainActor
final class BrowsingDataController: ObservableObject {
    static let shared = BrowsingDataController()
    @Published private(set) var action: BrowsingDataAction = .clearBrowsingData
    @Published private(set) var requestedRange: BrowsingDataTimeRange?
    let workflow: BrowsingDataWorkflow
    private var observation: AnyCancellable?
    var isClearing: Bool { workflow.isClearing }

    private init() {
        workflow = BrowsingDataWorkflow(services: BrowsingDataServices(
            clearReusableResponses: { cutoff in
                guard let cache = SharedContentCache.shared else { throw BrowsingDataWorkflowError.storageUnavailable }
                try await cache.removeResponses(since: cutoff)
            },
            persistLiveSession: {
                if !NativeTabCoordinator.shared.browsingDataModels.isEmpty {
                    try NativeTabCoordinator.shared.persistSessionAfterClearing()
                }
            },
            clearSavedVisits: { try SessionRestorationStore.shared.clearBrowsingData($0, since: $1) },
            clearHistory: { try BrowsingHistoryStore.shared.clear(since: $0) },
            clearInputDrafts: { try GeminiInputDraftStore.shared.clear(since: $0) }
        ))
        observation = workflow.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func register(_ session: BrowserSession) { workflow.register(session) }

    func present(_ action: BrowsingDataAction, range: BrowsingDataTimeRange? = nil) {
        guard !isClearing else { return }
        requestedRange = range
        self.action = action
    }

    func clear(_ action: BrowsingDataAction, range: BrowsingDataTimeRange) async throws {
        do { try await workflow.clear(action, range: range) }
        catch BrowsingDataWorkflowError.operationInProgress {
            throw NSError(domain: "BrowsingData", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Another clearing operation is already running."
            ])
        }
        catch BrowsingDataWorkflowError.failed(let stage, let underlying) {
            let item: String
            switch stage {
            case .reusableResponses: item = "cached responses"
            case .pendingWrites: item = "pending writes"
            case .liveSession: item = "the open-window session"
            case .savedVisits: item = "saved visits"
            case .history: item = "browsing history"
            case .inputDrafts: item = "input drafts"
            }
            let detail = underlying is BrowsingDataWorkflowError
                ? "The required local storage is unavailable."
                : "The local store could not be updated. Try again."
            throw NSError(domain: "BrowsingData", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Clearing \(item) failed. \(detail)",
                NSUnderlyingErrorKey: underlying
            ])
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
                            errorMessage = error.localizedDescription
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
