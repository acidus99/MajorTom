import AppKit
import MajorTomAppKitSupport
import MajorTomCore
import SwiftUI
import WebKit

/// Both pickers use the same native split-view shell and button bar.
struct ContentThemePickerLayout<Sidebar: View, Detail: View, Footer: View>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar().frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                detail().frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer()
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

struct ContentThemePreviewPane: View {
    let theme: ContentTheme?
    let html: String?
    let error: String?
    let appearance: ContentThemeAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let theme {
                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.label).font(.title2)
                    Text(theme.metadata["author"].map { "By \($0)" } ?? "Author not specified")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let description = theme.metadata["description"] {
                        Text(description).foregroundStyle(.secondary)
                    }
                    if let source = theme.sourceURL {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Source:").foregroundStyle(.secondary)
                            Link(source.absoluteString, destination: source)
                                .lineLimit(1).truncationMode(.middle)
                                .help(source.absoluteString)
                                .accessibilityLabel("Theme source")
                                .accessibilityValue(source.absoluteString)
                        }
                        .font(.subheadline)
                    }
                }
                .textSelection(.enabled)
                .padding([.top, .horizontal])

                if let error {
                    ContentUnavailableView("Couldn’t Preview Theme", systemImage: "exclamationmark.triangle", description: Text(error))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let html {
                    ThemePreviewWebView(html: html, appearance: appearance)
                        .accessibilityLabel("Theme reading preview")
                } else {
                    ProgressView("Loading Preview…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Select a Theme", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Preview WebKit is independent of browser tabs and has no navigation or resource bridge.
struct ThemePreviewWebView: NSViewRepresentable {
    let html: String
    let appearance: ContentThemeAppearance

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(PreformattedBlockPresentationScript.userScript)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let isDocument = navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank"
            return isDocument ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.querySelectorAll('details')[1]?.removeAttribute('open')", in: nil, in: .defaultClient) { _ in }
        }
    }
}
