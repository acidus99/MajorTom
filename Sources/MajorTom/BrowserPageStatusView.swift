import MajorTomCore
import SwiftUI

struct BrowserPageStatusView: View {
    @ObservedObject var session: BrowserSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    /// Cached history traversals can have identical status text, so include the
    /// document identity when restarting the dismissal task.
    private struct Update: Equatable {
        let documentURL: URL?
        let isLoading: Bool
        let text: String
    }

    var body: some View {
        HStack(spacing: 7) {
            if session.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(session.statusText)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .padding(8)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!isVisible)
        .task(id: Update(
            documentURL: session.activeWebDocumentURL,
            isLoading: session.isLoading,
            text: session.statusText
        )) {
            isVisible = true
            guard !session.isLoading else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1)) {
                isVisible = false
            }
        }
    }
}
