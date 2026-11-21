import AppKit
import MajorTomCore
import WebKit
import XCTest
@testable import MajorTomAppKitSupport

final class InlineImagePresentationTests: XCTestCase {
    @MainActor
    func testVisibleLinksAreSubmittedOnceAndOffWaitsForClick() async throws {
        let document = ImageTestDocument()
        try await document.load(document.html(mode: .whenVisible, count: 3))
        try await document.renderFrame()
        try await document.wait { document.messages.count == 3 }
        XCTAssertEqual(document.messages.compactMap { $0["id"] }, ["image-0", "image-1", "image-2"])
        _ = try await document.js("document.body.append(document.querySelector('main'))")
        XCTAssertEqual(document.messages.count, 3, "Moving an already discovered link must not enqueue it twice")

        let off = ImageTestDocument()
        try await off.load(off.html(mode: .off, count: 1))
        XCTAssertTrue(off.messages.isEmpty)
        _ = try await off.js("document.querySelector('main > a').click()")
        try await off.wait { off.messages.count == 1 }
        XCTAssertEqual(off.messages[0]["action"], "click")
    }

    @MainActor
    func testVisibleModeExcludesHiddenTabsAndToolbarAndOnlySubmitsOnce() async throws {
        let document = ImageTestDocument(hidden: true)
        try await document.load(document.html(mode: .whenVisible, count: 2, spacer: 1500))
        XCTAssertTrue(document.messages.isEmpty)
        // Keep the first link under the navigation overlay; the next is below the viewport.
        _ = try await document.js("""
        window.majorTomSetImageViewport(document.getElementById('image-0').getBoundingClientRect().bottom + 1);
        window.testHidden = false;
        document.dispatchEvent(new Event('visibilitychange'));
        """)
        try await document.renderFrame()
        XCTAssertTrue(document.messages.isEmpty)
        _ = try await document.js("window.majorTomSetImageViewport(0)")
        try await document.renderFrame()
        try await document.wait { document.messages.count == 1 }
        XCTAssertEqual(document.messages[0]["id"], "image-0")
        _ = try await document.js("document.getElementById('image-1').scrollIntoView()")
        try await document.renderFrame()
        try await document.wait { document.messages.count == 2 }
        _ = try await document.js("document.getElementById('image-0').scrollIntoView()")
        try await document.renderFrame()
        XCTAssertEqual(document.messages.count, 2, "Scrolling back must not submit a second request")
    }

    @MainActor
    func testPendingClockAndActiveSpinnerInBothAppearances() async throws {
        for theme in ContentTheme.bundled.filter({ ["system/alucardClassic.css", "system/draculaClassic.css"].contains($0.id) }) {
            let document = ImageTestDocument()
            try await document.load(document.html(mode: .whenVisible, count: 1, theme: theme))
            let original = try await document.js("document.querySelector('main > a').textContent") as? String
            for state in [GeminiImageLoader.State.pending, .requesting, .idle] {
                _ = try await document.js("window.majorTomSetImageState('image-0', '\(state.rawValue)')")
                let result = try await document.js("""
                (() => {
                  const line = document.getElementById('image-0');
                  const anchor = line;
                  const style = getComputedStyle(anchor, '::after');
                  return {
                    pending: line.classList.contains('is-image-pending'),
                    requesting: line.classList.contains('is-loading'), busy: line.getAttribute('aria-busy'),
                    mask: style.maskImage, animation: style.animationName, text: anchor.textContent,
                    href: anchor.href, content: style.content, description: anchor.getAttribute('aria-description')
                  };
                })()
                """) as? [String: Any]
                let values = try XCTUnwrap(result)
                XCTAssertEqual(values["pending"] as? Bool, state == .pending)
                XCTAssertEqual(values["requesting"] as? Bool, state == .requesting)
                XCTAssertEqual(values["busy"] as? String, String(state == .requesting))
                XCTAssertEqual(values["text"] as? String, original)
                XCTAssertEqual(values["href"] as? String, "gemini://example.invalid/image-0.png")
                if state == .pending {
                    XCTAssertNotEqual(values["mask"] as? String, "none", "The pending system symbol must render")
                    XCTAssertEqual(values["animation"] as? String, "none", "Pending must not animate")
                } else if state == .requesting {
                    XCTAssertNotEqual(values["animation"] as? String, "none", "An active transfer must animate")
                } else {
                    XCTAssertEqual(values["content"] as? String, "none")
                    XCTAssertNil(values["description"] as? String)
                }
            }
            _ = try await document.js("window.majorTomSetImageState('image-0', 'pending'); document.querySelector('main > a').click()")
            try await document.wait { document.messages.contains { $0["action"] == "click" } }
        }
    }

    @MainActor
    func testRestoringScrollDoesNotLoadLinksFromTheHiddenInitialViewport() async throws {
        // History restoration hides the document until its saved offset is applied.
        // Geometry alone must not submit images from the page's temporary top position.
        let document = ImageTestDocument()
        try await document.load(document.html(mode: .whenVisible, count: 2, spacer: 1500,
            extraCSS: "html { visibility: hidden; }"))
        try await document.renderFrame()
        XCTAssertTrue(document.messages.isEmpty)
        _ = try await document.js("""
        document.getElementById('image-1').scrollIntoView();
        document.documentElement.style.setProperty('visibility', 'visible', 'important');
        """)
        try await document.renderFrame()
        try await document.wait { document.messages.count == 1 }
        XCTAssertEqual(document.messages.first?["id"], "image-1")
    }

    @MainActor
    func testStateBridgeUsesDocumentIdentityAndIgnoresOldDocuments() async throws {
        // A late callback must not annotate a replacement document with reused IDs.
        let document = ImageTestDocument()
        try await document.load(document.html(mode: .off, count: 1))
        let locationValue = try await document.js("location.href")
        let location = try XCTUnwrap(locationValue as? String)
        let url = try XCTUnwrap(URL(string: location))
        _ = try await document.js(InlineImagePresentationScript.stateUpdateScript(
            identifier: "image-0", state: .pending, documentURL: url
        ))
        let pending = try await document.js("document.getElementById('image-0').classList.contains('is-image-pending')") as? Bool
        XCTAssertEqual(pending, true)
        _ = try await document.js(InlineImagePresentationScript.stateUpdateScript(
            identifier: "image-0", state: .requesting, documentURL: URL(string: "majortom-document://document/old")!
        ))
        let unchanged = try await document.js("document.getElementById('image-0').classList.contains('is-image-pending')") as? Bool
        XCTAssertEqual(unchanged, true)
    }

    @MainActor
    func testStopClearsUnfinishedImagesAndAllowsManualRetryWithoutRestartingAutomaticLoads() async throws {
        // Stopping an image used to leave its expanded placeholder behind, so the
        // next click merely collapsed it instead of retrying the request.
        let document = ImageTestDocument()
        try await document.load(document.html(mode: .whenVisible, count: 3))
        try await document.renderFrame()
        try await document.wait { document.messages.count == 3 }
        _ = try await document.js("""
        for (let index = 0; index < 3; index++) {
          const line = document.getElementById(`image-${index}`);
          const figure = document.createElement('figure');
          figure.className = 'inline-image';
          figure.id = `figure-${index}`;
          line.after(figure);
        }
        window.majorTomSetImageState('image-0', 'pending');
        window.majorTomSetImageState('image-1', 'requesting');
        document.getElementById('image-2').dataset.mtImageLoaded = 'true';
        """)
        let locationValue = try await document.js("location.href")
        let location = try XCTUnwrap(locationValue as? String)
        let url = try XCTUnwrap(URL(string: location))
        _ = try await document.js(InlineImagePresentationScript.stopScript(
            identifiers: ["image-0", "image-1"], documentURL: url
        ))
        let state = try await document.js("""
        (() => {
          const stopped = ['image-0', 'image-1'].map(id => document.getElementById(id));
          return {
            indicatorsGone: stopped.every(line => !line.classList.contains('is-loading') && !line.classList.contains('is-image-pending')),
            notBusy: stopped.every(line => line.getAttribute('aria-busy') === 'false'),
            unfinishedGone: !document.getElementById('figure-0') && !document.getElementById('figure-1'),
            finishedKept: !!document.getElementById('figure-2'),
            linkKept: stopped.every(line => line.matches('a[href]'))
          };
        })()
        """) as? [String: Bool]
        let values = try XCTUnwrap(state)
        XCTAssertTrue(values.values.allSatisfy { $0 })
        // Links arriving after Stop must not quietly restart automatic loading.
        _ = try await document.js("""
        const later = document.getElementById('image-0').cloneNode(true);
        later.id = 'image-later';
        document.querySelector('main').append(later);
        """)
        try await document.renderFrame()
        XCTAssertEqual(document.messages.count, 3)
        _ = try await document.js("document.querySelector('#image-0').click()")
        try await document.wait { document.messages.count == 4 }
        XCTAssertEqual(document.messages.last?["id"], "image-0")
        XCTAssertEqual(document.messages.last?["action"], "click")
        // A new document starts with automatic loading enabled again.
        let reloaded = ImageTestDocument()
        try await reloaded.load(reloaded.html(mode: .whenVisible, count: 1))
        try await reloaded.renderFrame()
        try await reloaded.wait { reloaded.messages.count == 1 }
        XCTAssertEqual(reloaded.messages.first?["action"], "load")
    }

}

@MainActor
private final class ImageTestDocument: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var messages: [[String: String]] = []
    private var continuation: CheckedContinuation<Void, any Error>?

    init(hidden: Bool = false) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Control tab visibility independently of the headless test runner's windows.
        config.userContentController.addUserScript(WKUserScript(source: "window.testHidden = \(hidden); Object.defineProperty(document, 'hidden', {get: () => window.testHidden});", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        config.userContentController.addUserScript(InlineImagePresentationScript.userScript)
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        super.init()
        let receiver = ImageMessageReceiver()
        receiver.document = self
        config.userContentController.add(receiver, contentWorld: .defaultClient, name: "majorTomInlineImage")
        view.navigationDelegate = self
    }

    func html(mode: SameCapsuleImageLoading, count: Int, spacer: Int = 0, theme: ContentTheme? = nil, extraCSS: String = "") -> String {
        let renderer = HTMLDocumentStreamRenderer()
        let css = (theme.map { $0.stylesheet(for: $0.appearance) } ?? ContentThemeStylesheets.base) + "\n" + extraCSS
            + "\n:root { --mt-image-pending-icon: \(InlineImagePresentationScript.pendingIconCSS); }"
        var data = renderer.documentStart(themeCSS: css, baseURL: URL(string: "gemini://example.invalid/")!)
        for index in 0..<count {
            if index > 0, spacer > 0 { data.append(Data("<div style=\"height:\(spacer)px\"></div>".utf8)) }
            data.append(renderer.render(.link(destination: "image-\(index).png", label: "Image \(index)"),
                linkIdentifier: "image-\(index)", isExpandableImage: true, imageLoading: mode))
        }
        data.append(renderer.documentEnd())
        return String(decoding: data, as: UTF8.self)
    }

    func js(_ script: String) async throws -> Any? { try await view.evaluateJavaScript(script, contentWorld: .defaultClient) }
    func renderFrame() async throws {
        // Flush layout without requesting a screenshot. WebKit snapshots of a hidden
        // restoration document can stall even though its DOM and observers are ready.
        _ = try await js("document.documentElement.getBoundingClientRect().height")
        try await Task.sleep(for: .milliseconds(20))
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for image discovery")
    }
    func load(_ html: String, baseURL: URL? = nil) async throws {
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let pending = self.continuation else { return }
            self.continuation = nil
            self.view.stopLoading()
            pending.resume(throwing: URLError(.timedOut))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString(html, baseURL: baseURL)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

@MainActor
private final class ImageMessageReceiver: NSObject, WKScriptMessageHandler {
    weak var document: ImageTestDocument?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: String] { document?.messages.append(body) }
    }
}
