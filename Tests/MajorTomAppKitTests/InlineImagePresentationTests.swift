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
    func testImageAndCaptionAppearOnlyAfterSuccessfulDecode() async throws {
        // The old insertion path exposed a filename and empty space before the
        // response arrived, and accepted broken image bytes as a completed image.
        let document = ImageTestDocument()
        try await document.load(document.html(mode: .whenVisible, count: 1))
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = URL(string: "data:image/png;base64,\(png.base64EncodedString())")!
        _ = try await document.js("""
        window.originalImageDecode = HTMLImageElement.prototype.decode;
        HTMLImageElement.prototype.decode = function() {
          return new Promise((resolve, reject) => {
            window.finishImageDecode = () => window.originalImageDecode.call(this).then(resolve, reject);
          });
        };
        undefined;
        """)
        let insertion = Task { try await document.insertImage(source: source) }
        try await document.waitForJS("typeof window.finishImageDecode === 'function'")
        let before = try await document.js("document.querySelectorAll('figure, figcaption').length") as? Int
        XCTAssertEqual(before, 0, "Decoding must not reserve layout space or expose a caption")
        _ = try await document.js("window.finishImageDecode(); undefined")
        let inserted = try await insertion.value
        XCTAssertTrue(inserted)
        let loaded = try await document.js("""
        (() => {
          const image = document.querySelector('figure img');
          const line = document.getElementById('image-0');
          return image.naturalWidth === 8 && image.naturalHeight === 8 &&
            line.dataset.mtImageLoaded === 'true' &&
            document.querySelector('figcaption').textContent.includes('8 x 8');
        })()
        """) as? Bool
        XCTAssertEqual(loaded, true)
        _ = try await document.js(BrowserDocumentScript.removeImage(lineIdentifier: "image-0"))
        _ = try await document.js("HTMLImageElement.prototype.decode = window.originalImageDecode; undefined")
        let invalid = try await document.insertImage(source: URL(string: "data:image/png;base64,AQID")!)
        XCTAssertFalse(invalid)
        let after = try await document.js("document.querySelectorAll('figure, figcaption').length") as? Int
        XCTAssertEqual(after, 0, "Invalid image bytes must leave the original link alone")
    }

    @MainActor
    func testLoadedImageLinksToggleInBothLoadingModesWithoutRestartingAutoload() async throws {
        // Successfully autoloaded images used to bypass the toggle and navigate
        // instead, so the original link could not collapse them with a plain click.
        for mode in [SameCapsuleImageLoading.off, .whenVisible] {
            let document = ImageTestDocument()
            try await document.load(document.html(mode: mode, count: 1))
            try await document.renderFrame()
            if mode == .whenVisible { try await document.wait { document.messages.count == 1 } }
            document.resources.svg = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
              <rect width="8" height="8" fill="blue"/>
            </svg>
            """.utf8)
            let inserted = try await document.insertImage(source: URL(string: "majortom-resource://image/test.png")!)
            XCTAssertTrue(inserted)
            let before = document.messages.count
            // HTMLElement.click() also exercises the click path used by keyboard activation.
            _ = try await document.js("document.getElementById('image-0').focus(); document.getElementById('image-0').click()")
            try await document.wait { document.messages.count == before + 1 }
            XCTAssertEqual(document.messages.last?["action"], "click")
            XCTAssertEqual(document.messages.last?["id"], "image-0")

            // Apply the browser's collapse update and rediscover the moved link.
            // A deliberate collapse must not immediately trigger another autoload.
            _ = try await document.js(BrowserDocumentScript.removeImage(lineIdentifier: "image-0"))
            _ = try await document.js("document.body.append(document.querySelector('main'))")
            try await document.renderFrame()
            let remaining = try await document.js("document.querySelectorAll('figure').length") as? Int
            XCTAssertEqual(remaining, 0)
            XCTAssertEqual(document.messages.count, before + 1)

            _ = try await document.js("document.getElementById('image-0').click()")
            try await document.wait { document.messages.count == before + 2 }
            XCTAssertEqual(document.messages.last?["action"], "click", "The collapsed link must allow manual expansion again")
        }
    }

    @MainActor
    func testStopDuringDecodePreventsLateInsertion() async throws {
        let document = ImageTestDocument()
        try await document.load(document.html(mode: .whenVisible, count: 1))
        _ = try await document.js("""
        HTMLImageElement.prototype.decode = function() {
          Object.defineProperty(this, 'naturalWidth', { value: 1 });
          Object.defineProperty(this, 'naturalHeight', { value: 1 });
          return new Promise(resolve => { window.finishImageDecode = resolve; });
        };
        undefined;
        """)
        let insertion = Task { try await document.insertImage(source: URL(string: "data:image/png;base64,AQID")!) }
        try await document.waitForJS("typeof window.finishImageDecode === 'function'")
        _ = try await document.js("window.majorTomStopImages(['image-0']); window.finishImageDecode(); undefined")
        let inserted = try await insertion.value
        XCTAssertFalse(inserted)
        let count = try await document.js("document.querySelectorAll('figure').length") as? Int
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testFailureIsAccessibleAndAutomaticLinkResumesOrdinaryNavigationInBothAppearances() async throws {
        for theme in ContentTheme.bundled.filter({ ["system/alucardClassic.css", "system/draculaClassic.css"].contains($0.id) }) {
            let document = ImageTestDocument()
            try await document.load(document.html(mode: .whenVisible, count: 1, theme: theme))
            try await document.renderFrame()
            try await document.wait { document.messages.count == 1 }
            let message = "Image unavailable. The capsule returned Gemini status 51: <missing>. Open the link to view the response."
            _ = try await document.js(InlineImagePresentationScript.failureUpdateScript(identifier: "image-0", message: message))
            // An idle callback must not erase terminal feedback.
            _ = try await document.js("window.majorTomSetImageState('image-0', 'idle')")
            let result = try await document.js("""
            (() => {
              const line = document.getElementById('image-0');
              line.focus();
              return { title: line.title, description: line.getAttribute('aria-description'),
                busy: line.getAttribute('aria-busy'), mask: getComputedStyle(line, '::after').maskImage,
                focused: document.activeElement === line, text: line.textContent, href: line.href,
                navigates: line.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 })) };
            })()
            """) as? [String: Any]
            let values = try XCTUnwrap(result)
            XCTAssertEqual(values["title"] as? String, message)
            XCTAssertEqual(values["description"] as? String, message)
            XCTAssertEqual(values["busy"] as? String, "false")
            XCTAssertNotEqual(values["mask"] as? String, "none")
            XCTAssertEqual(values["focused"] as? Bool, true)
            XCTAssertEqual(values["navigates"] as? Bool, true)
            XCTAssertEqual(values["href"] as? String, "gemini://example.invalid/image-0.png")
            XCTAssertEqual(document.messages.count, 1, "A failed autoload must not intercept a click to retry")
            _ = try await document.js("window.majorTomSetImageState('image-0', 'pending')")
            let failed = try await document.js("document.getElementById('image-0').classList.contains('is-image-failed')") as? Bool
            XCTAssertEqual(failed, false, "An explicit context-menu retry must clear failure feedback")
        }
    }

    @MainActor
    func testSVGImageCannotRunScriptsOrFetchNestedResources() async throws {
        // A .png link can return image/svg+xml: extension hints are not a security boundary.
        let document = ImageTestDocument()
        try await document.load(document.html(mode: .whenVisible, count: 1))
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"
          onload="window.webkit.messageHandlers.svgProbe.postMessage('onload')">
          <script>window.webkit.messageHandlers.svgProbe.postMessage('script')</script>
          <script href="majortom-resource://probe/script.js"/>
          <style>@import url('majortom-resource://probe/style.css');
            @font-face { font-family: probe; src: url('majortom-resource://probe/font.woff'); }
            text { font-family: probe; }
          </style>
          <rect width="32" height="32" fill="blue"/>
          <image href="majortom-resource://probe/nested.png" width="1" height="1"/>
          <foreignObject width="1" height="1"><div xmlns="http://www.w3.org/1999/xhtml">
            <script>window.webkit.messageHandlers.svgProbe.postMessage('html-script')</script>
            <img src="majortom-resource://probe/foreign.png" onerror="window.webkit.messageHandlers.svgProbe.postMessage('error')"/>
          </div></foreignObject>
          <text y="20">Test</text>
        </svg>
        """
        document.resources.svg = Data(svg.utf8)
        let inserted = try await document.insertImage(source: URL(string: "majortom-resource://image/payload.png")!)
        XCTAssertTrue(inserted, "SVG is rendered strictly in image mode")
        try await document.renderFrame()
        XCTAssertEqual(document.resources.requests.map(\.host), ["image"], "SVG must not fetch nested images, scripts, CSS or fonts")
        XCTAssertTrue(document.resources.scriptMessages.isEmpty, "SVG script and event handlers must never execute")
        let embeddedDocuments = try await document.js("document.querySelectorAll('svg, script, iframe, object, embed').length") as? Int
        XCTAssertEqual(embeddedDocuments, 0, "Fetched bytes must never become page markup or an embedded document")
        XCTAssertEqual(document.messages.filter { $0["action"] == "click" }.count, 0)
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
    let resources = ImageTestResources()
    var messages: [[String: String]] = []
    private var continuation: CheckedContinuation<Void, any Error>?

    init(hidden: Bool = false) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(resources, forURLScheme: "majortom-resource")
        config.userContentController.add(resources, name: "svgProbe")
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
            + "\n:root { --mt-image-pending-icon: \(InlineImagePresentationScript.pendingIconCSS); --mt-image-failed-icon: \(InlineImagePresentationScript.failureIconCSS); }"
        var data = renderer.documentStart(themeCSS: css, baseURL: URL(string: "gemini://example.invalid/")!)
        for index in 0..<count {
            if index > 0, spacer > 0 { data.append(Data("<div style=\"height:\(spacer)px\"></div>".utf8)) }
            data.append(renderer.render(.link(destination: "image-\(index).png", label: "Image \(index)"),
                linkIdentifier: "image-\(index)", isExpandableImage: true, imageLoading: mode))
        }
        data.append(renderer.documentEnd())
        return String(decoding: data, as: UTF8.self)
    }

    func insertImage(source: URL) async throws -> Bool {
        let figure = String(decoding: HTMLDocumentStreamRenderer().renderInlineImage(resourceURL: source,
            linkURL: URL(string: "gemini://example.invalid/image-0.png")!, altText: "Image", figureIdentifier: "figure-0",
            fileName: "image-0.png", mimeType: "image/png", sizeDescription: "small", figureClass: "inline-image"), as: UTF8.self)
        return try await view.callAsyncJavaScript(BrowserDocumentScript.insertImage(lineIdentifier: "image-0", figure: figure),
            in: nil, contentWorld: .defaultClient) as? Bool == true
    }
    func waitForJS(_ expression: String) async throws {
        for _ in 0..<200 {
            if try await js(expression) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for image decoding")
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

@MainActor
private final class ImageTestResources: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    var svg = Data()
    var requests: [URL] = []
    var scriptMessages: [String] = []
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        requests.append(url)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/svg+xml", expectedContentLength: svg.count, textEncodingName: nil))
        urlSchemeTask.didReceive(svg)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        scriptMessages.append(String(describing: message.body))
    }
}
