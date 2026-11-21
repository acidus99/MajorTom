import AppKit
import MajorTomCore
import WebKit

public struct ResolvedContentTheme: Equatable, Sendable {
    public let theme: ContentTheme
    public let appearance: ContentThemeAppearance
    public let colors: [String: ContentThemeColor]

    public var css: String { theme.stylesheet(for: appearance) }
    public var palette: ContentThemePalette {
        ContentThemePalette(
            background: colors["background"]!, foreground: colors["foreground"]!,
            codeBackground: colors["codeBackground"]!, codeForeground: colors["codeForeground"]!
        )
    }
}

/// Resolves arbitrary CSS with the same engine that draws the document. Core receives
/// plain colors, preserving its deterministic ANSI contrast boundary.
@MainActor
public final class ContentThemeResolver: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<ResolvedContentTheme, any Error>?
    private var timeout: Task<Void, Never>?
    private var theme: ContentTheme?
    private var appearance = ContentThemeAppearance.dark

    public override init() { super.init() }

    public func resolve(_ theme: ContentTheme, appearance: ContentThemeAppearance) async throws -> ResolvedContentTheme {
        precondition(continuation == nil)
        self.theme = theme
        self.appearance = appearance
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        view.navigationDelegate = self
        webView = view
        let renderer = HTMLDocumentStreamRenderer()
        var sample = renderer.documentStart(themeCSS: theme.stylesheet(for: appearance), appearance: appearance)
        let events: [GemtextEvent] = [
            .heading(level: 1, text: "Heading"),
            .text("Text **Strong** *Emphasis* `Code`"),
            .link(destination: "gemini://example.invalid/", label: "Link"),
            .quote("Quotation"), .blank,
            .beginPreformatted(altText: "Art caption"), .preformattedLine("Art"), .endPreformatted
        ]
        for event in events { sample.append(renderer.render(event)) }
        sample.append(renderer.renderInlineImage(
            resourceURL: URL(string: "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!,
            linkURL: URL(string: "gemini://example.invalid/image.gif")!,
            altText: "Sample", figureIdentifier: "sample-image", fileName: "Caption"
        ))
        sample.append(renderer.documentEnd())
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ResolutionError.failed))
            }
            view.loadHTMLString(String(decoding: sample, as: UTF8.self), baseURL: nil)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.colorScript, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, let theme = self.theme else { return }
            do {
                let value = try result.get()
                guard let values = value as? [String: [Int]] else { throw ResolutionError.failed }
                var colors: [String: ContentThemeColor] = [:]
                for (role, rgb) in values {
                    guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else {
                        throw ResolutionError.failed
                    }
                    colors[role] = ContentThemeColor(red: UInt8(rgb[0]), green: UInt8(rgb[1]), blue: UInt8(rgb[2]))
                }
                guard ["background", "foreground", "codeBackground", "codeForeground"].allSatisfy({ colors[$0] != nil }) else {
                    throw ResolutionError.failed
                }
                self.finish(.success(ResolvedContentTheme(theme: theme, appearance: self.appearance, colors: colors)))
            } catch { self.finish(.failure(error)) }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<ResolvedContentTheme, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }

    private enum ResolutionError: Error { case failed }

    private static let colorScript = """
    (() => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 1;
      canvas.style.display = 'none';
      document.documentElement.append(canvas);
      const context = canvas.getContext('2d', {willReadFrequently: true});
      const sample = (selector, property) => {
        const element = document.querySelector(selector);
        context.clearRect(0, 0, 1, 1);
        context.fillStyle = 'Canvas';
        context.fillRect(0, 0, 1, 1);
        const ancestors = [];
        for (let node = element; node; node = node.parentElement) ancestors.unshift(node);
        for (const node of ancestors) {
          context.fillStyle = getComputedStyle(node).backgroundColor;
          context.fillRect(0, 0, 1, 1);
        }
        if (property !== 'backgroundColor') {
          context.fillStyle = getComputedStyle(element).getPropertyValue(property);
          context.fillRect(0, 0, 1, 1);
        }
        return Array.from(context.getImageData(0, 0, 1, 1).data).slice(0, 3);
      };
      const colors = {
        background: sample('body', 'backgroundColor'),
        foreground: sample('main', 'color'),
        codeBackground: sample('pre', 'backgroundColor'),
        codeForeground: sample('pre', 'color'),
        heading: sample('h1', 'color'), link: sample('a', 'color'),
        strong: sample('strong', 'color'), emphasis: sample('em', 'color'),
        code: sample('code', 'color'), codeSurface: sample('code', 'backgroundColor'),
        muted: sample('figcaption', 'color'),
        quote: sample('blockquote', 'color'), quoteSurface: sample('blockquote', 'backgroundColor')
      };
      canvas.remove();
      return colors;
    })()
    """
}
