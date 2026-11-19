import AppKit
import MajorTomCore
import WebKit
import XCTest
@testable import MajorTomAppKitSupport

final class BrowserDocumentScriptTests: XCTestCase {
    @MainActor
    func testMessagesFromReplacedDocumentsAndSwipePreviewsCannotActOnActiveVisit() async throws {
        let document = ScriptTestDocument()
        defer { document.close() }
        let first = URL(string: "majortom-test://document/first")!
        let second = URL(string: "majortom-test://document/second")!
        try await document.load(first)
        let oldMessage = try await document.contextMessage()
        XCTAssertTrue(DocumentMessageFence.accepts(oldMessage, currentDocumentURL: first))
        try await document.load(second)
        let currentMessage = try await document.contextMessage()
        XCTAssertTrue(DocumentMessageFence.accepts(currentMessage, currentDocumentURL: second))
        // A queued callback retains WebKit's original frame identity across replacement.
        XCTAssertFalse(DocumentMessageFence.accepts(oldMessage, currentDocumentURL: second))
        XCTAssertFalse(DocumentMessageFence.accepts(currentMessage, currentDocumentURL: first),
            "A separately hosted swipe preview must not send actions to the active visit")
        XCTAssertFalse(DocumentMessageFence.accepts(currentMessage, currentDocumentURL: nil))
        let payload = try XCTUnwrap(currentMessage.body as? [String: String])
        XCTAssertEqual(payload["href"], "gemini://example.invalid/linked")
    }

    @MainActor
    func testLiveThemeUpdatePreservesDocumentTextSelectionAndReadingPosition() async throws {
        let document = ScriptTestDocument()
        defer { document.close() }
        let url = URL(string: "majortom-test://document/theme")!
        try await document.load(url)
        _ = try await document.js("""
        const range = document.createRange();
        range.selectNodeContents(document.getElementById('selected'));
        getSelection().removeAllRanges(); getSelection().addRange(range);
        window.scrollTo(0, 300);
        """)
        let before = try await document.snapshot()
        for (appearance, background, foreground) in [("light", "white", "black"), ("dark", "black", "white")] {
            _ = try await document.js(BrowserDocumentScript.themeUpdate(
                css: "body { background: \(background); color: \(foreground); } main { max-width: 80ch; }",
                appearance: appearance
            ))
            let after = try await document.snapshot()
            XCTAssertEqual(after["text"] as? String, before["text"] as? String)
            XCTAssertEqual(after["selection"] as? String, "Selected fixture text")
            XCTAssertEqual(after["scroll"] as? Double, before["scroll"] as? Double)
            XCTAssertEqual(after["location"] as? String, url.absoluteString)
            XCTAssertEqual(after["appearance"] as? String, appearance)
            XCTAssertEqual(after["background"] as? String, appearance == "light" ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)")
        }
    }
}

@MainActor
private final class ScriptTestDocument: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private var loadContinuation: CheckedContinuation<Void, any Error>?
    private var messageContinuation: CheckedContinuation<WKScriptMessage, any Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(ScriptTestSchemeHandler(), forURLScheme: "majortom-test")
        configuration.userContentController.addUserScript(BrowserDocumentScript.contextMenu)
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        view.navigationDelegate = self
        configuration.userContentController.add(self, contentWorld: .defaultClient, name: BrowserDocumentScript.contextMenuName)
    }

    func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        loadContinuation?.resume(throwing: CancellationError()); loadContinuation = nil
        messageContinuation?.resume(throwing: CancellationError()); messageContinuation = nil
    }

    func load(_ url: URL) async throws {
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.close()
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            view.load(URLRequest(url: url))
        }
    }

    func contextMessage() async throws -> WKScriptMessage {
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            messageContinuation?.resume(throwing: URLError(.timedOut)); messageContinuation = nil
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            messageContinuation = continuation
            Task { @MainActor in
                do {
                    _ = try await js("document.querySelector('a').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true}))")
                } catch {
                    messageContinuation?.resume(throwing: error); messageContinuation = nil
                }
            }
        }
    }

    func js(_ source: String) async throws -> Any? {
        try await view.evaluateJavaScript(source, contentWorld: .defaultClient)
    }

    func snapshot() async throws -> [String: Any] {
        let result = try await js("""
        ({text: document.body.textContent, selection: getSelection().toString(), scroll: scrollY,
          location: location.href, appearance: document.documentElement.dataset.appearance,
          background: getComputedStyle(document.body).backgroundColor})
        """)
        return try XCTUnwrap(result as? [String: Any])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume(); loadContinuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadContinuation?.resume(throwing: error); loadContinuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadContinuation?.resume(throwing: error); loadContinuation = nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        messageContinuation?.resume(returning: message); messageContinuation = nil
    }
}

@MainActor
private final class ScriptTestSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let html = """
        <!doctype html><html data-appearance="dark"><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style id="majortom-theme">body { background: black; color: white; }</style></head>
        <body><main><p id="selected">Selected fixture text</p><a href="gemini://example.invalid/linked">Fixture link</a>
        <div style="height: 2000px">Reading fixture</div></main></body></html>
        """
        urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(Data(html.utf8))
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
