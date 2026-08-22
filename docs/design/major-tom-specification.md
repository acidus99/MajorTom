# Major Tom Product Specification

Status: Working document

This document defines what Major Tom is intended to be and how the product must behave. It is authoritative for product intent. The existing C#/Avalonia application is evidence of prior decisions and behavior, but it is not the specification for the native macOS implementation.

## 1. Product Vision

Major Tom will be the best Gemini browser for macOS.

It will provide a fast, clean, beautiful, and enjoyable Gemini browsing experience built around native macOS conventions. It should feel as natural and coherent on a Mac as Safari, while being designed specifically for the Gemini protocol and the culture of Gemini.

Most existing Gemini browsers use cross-platform interfaces that look and behave out of place on macOS. Major Tom exists to reject that lowest-common-denominator experience. Native Mac quality is not optional polish; it is part of whether the product is correct.

## 2. Definition of Product Success

Major Tom succeeds when:

- It is the most polished and capable Gemini browser available for macOS.
- Common actions feel immediately familiar to a Mac user, particularly a Safari user.
- The interface is fast, restrained, legible, and visually coherent with macOS.
- Browsing and reading Gemini content is beautiful and enjoyable rather than merely functional.
- Text, color, symbols, emoji, menus, windows, keyboard shortcuts, gestures, dialogs, and accessibility behave like parts of a real Mac application.
- Gemini-specific behavior feels intentionally designed rather than forced into conventions inherited from HTTP or the modern Web.

Success is not defined solely by protocol compatibility or feature count. An interaction that technically works but feels clumsy, foreign, visually poor, or inconsistent with macOS is not finished.

## 3. Product Principles

### 3.1 Mac-first, not merely Mac-compatible

Major Tom is a macOS application. It does not need to preserve cross-platform abstractions or accommodate other desktop platforms. Engineering choices should optimize for the quality of the Mac experience.

### 3.2 Safari is the primary interaction reference

Where an established Safari or macOS convention applies, Major Tom should normally follow it. This includes terminology, commands, keyboard shortcuts, menu placement, window behavior, navigation feedback, contextual actions, and other interaction details.

Safari is a behavioral reference, not a requirement to reproduce every visual detail or import features that do not make sense for Gemini.

### 3.3 Gemini is not a reduced version of the Web

Major Tom should respect the Gemini protocol and its simpler content model. It should not attempt to turn Gemini capsules into ordinary websites or add modern-Web complexity for its own sake.

### 3.4 Reading quality is a core feature

Typography, spacing, line length, color, emoji rendering, image presentation, selection, scrolling, and accessibility are product behavior. They are not implementation details to be accepted at framework defaults without review.

Major Tom may provide opinionated, user-configurable quality-of-life enhancements beyond the presentation rules defined by standard Gemtext. Examples include automatically retrieving and displaying images linked from the same capsule and recognizing limited inline conventions such as emphasis or code-like text.

These enhancements must preserve the capsule author's source and meaning. Major Tom controls the quality and convenience of presentation; it does not silently rewrite the underlying document.

### 3.5 Fast and clean

The application should start quickly, respond immediately to local interaction, clearly communicate network activity, and keep browser chrome subordinate to content.

### 3.6 Beautiful and fun to use

Major Tom may have personality. Restraint does not require sterility. Visual craft, delightful details, and the Bowie-inspired identity are compatible with a serious native browser, provided they do not interfere with clarity or Mac conventions.

### 3.7 Native quality is part of correctness

Features are not complete merely because their principal action works. Relevant native details—focus, selection, menus, shortcuts, gestures, accessibility, state restoration, error presentation, and system appearance—must also be considered.

## 4. Product Boundaries

Major Tom is not:

- A cross-platform Gemini browser.
- A mechanical Swift translation of the existing C#/Avalonia application.
- A generic Web browser with `gemini://` added to it.
- A visual clone of Safari that ignores Gemini-specific needs.
- A protocol demonstration where basic connectivity is considered sufficient product quality.

The product specification does not prescribe a document-rendering technology. The rendering architecture will be selected only after the required content behavior, interactions, accessibility, performance, and appearance have been defined.

## 5. Content Fidelity and Presentation Enhancements

### 5.1 Source is authoritative

The exact response body received from a capsule is the authoritative source document. Presentation enhancements must not modify the stored source, View Source output, or bytes saved through Save Page As.

### 5.2 Presentation may be richer than standard Gemtext

Major Tom may interpret conservative, commonly understood conventions that Gemtext itself does not formally define. It may also retrieve related resources to improve the reading experience.

Initial examples include:

- Automatically retrieving and displaying linked images hosted by the same capsule as the Gemtext document.
- Displaying recognized inline emphasis conventions as styled text.
- Displaying recognized inline code or filename conventions in a fixed-width font.

### 5.3 Enhancements are explicit product features

Each enhancement must have defined recognition rules, defaults, settings behavior, security boundaries, failure behavior, and interactions with selection, copying, accessibility, caching, and saving. Enhancement syntax must not be applied inside contexts where it would alter literal content, such as preformatted blocks.

Quality-of-life enhancements will initially be controlled through individual settings. The initial native version will not include a master **Strict Gemtext** setting; users who want an unenhanced presentation can disable the optional features individually.

### 5.4 Rendering must be reversible

The application must be able to re-render a previously retrieved document when appearance or quality-of-life settings change, without requesting the document again and without attempting to reconstruct its source from rendered output.

### 5.5 Automatic same-capsule images

Automatically displaying linked images from the same capsule is an individually configurable quality-of-life enhancement. It will be enabled by default.

For this feature, the same capsule means the same hostname and effective Gemini port as the containing Gemtext document.

The feature must behave as follows:

- Only links reasonably identified as potential images are eligible for automatic retrieval.
- Retrieved content is displayed as an image only when the response declares an `image/*` MIME type.
- Image requests use the same Gemini networking, certificate validation, and trusted-identity rules as top-level navigation.
- Automatic image retrieval is concurrent but bounded. A document cannot cause unbounded simultaneous requests or resource consumption.
- A failed image request does not disrupt the document. The original link remains available and usable.
- An automatic redirect that would leave the originating capsule is not followed automatically.
- Cross-capsule images are not retrieved automatically. Their links remain available for explicit user navigation.
- Disabling the enhancement prevents automatic image requests but does not remove or hide image links.

## 6. Appearance and Themes

Major Tom has two independent appearance systems: application appearance and content themes.

### 6.1 Application appearance

Application appearance controls browser chrome and browser-owned interface, including windows, toolbars, tabs, menus, settings, status presentation, dialogs, and browser-generated pages where appropriate.

The application appearance options are:

- **System:** follow the current macOS appearance.
- **Light:** always use the light application appearance.
- **Dark:** always use the dark application appearance.

### 6.2 Content themes

Content themes control the document surface, including typography, measure, spacing, colors, links, quotations, preformatted content, inline code, and image presentation.

The initial content-theme choices are:

- **Automatic:** select a suitable content theme based on the effective application appearance.
- **Dracula Light:** always use the light Dracula reading theme.
- **Dracula Dark:** always use the dark Dracula reading theme.
- **Dracula Classic:** use the full classic Dracula semantic palette for headings,
  links and interaction states, emphasis, code, quotations, lists, selection,
  warnings, generated errors, and source-view furniture.
- **Ocean:** a deep navy and turquoise theme with sky-blue links and coral accents.
- **Forest:** an Enchanted Grove-inspired theme built from gum-leaf, laurel,
  hippie-green, tom-thumb, and heavy-metal greens, with accessible pale-green
  text roles and restrained warm interaction accents.
- **Creamsicle:** an Orange Creamsicle-inspired vanilla theme built around
  chardonnay, yellow-orange, and vivid orange surfaces, with darkened orange
  text roles and complementary teal links for accessible contrast.
- **Sand Dunes:** a light sand and sandstone theme with terracotta structure and oasis-teal links.

Semantic themes supply a compact role-based palette for the document background,
surface, foreground, muted text, headings, links, link interaction, accents, strong
and emphasized text, code, danger, and selection. One shared stylesheet maps those
tokens onto Gemtext and browser-generated content, so adding a palette does not
introduce theme-specific document selectors.

Additional content themes may be added later without changing the distinction between content and application appearance.

### 6.3 Content width

Content width applies consistently to Gemtext, plain-text documents, and source views. The options are:

- **Narrow:** the default 48-rem content container.
- **Wide:** a 56-rem content container.
- **Full:** use the available window width while retaining the document's side padding.

Changing content width updates open documents without another network request.

### 6.4 Independence

An explicitly selected content theme remains fixed when the application or macOS appearance changes. This allows combinations such as dark browser chrome with a light reading surface.

When **Automatic** is selected, the content theme tracks the application's effective light or dark appearance.

Changing either appearance setting must update applicable open windows and documents without requiring another network request.

## 7. Product and Engineering Responsibilities

The product manager defines vision, scope, roadmap, priorities, expected behavior, and the meaning of success. The senior engineer owns architecture, technical design, implementation, testing, security, maintainability, and release engineering.

Technical choices that materially affect product behavior, scope, risk, or future flexibility must be presented to the product manager in product terms. Implementation details that do not change those things remain engineering decisions.

The team will use lightweight product development practices. Formal epics, user stories, estimates, and similar process will be introduced only if they begin solving a concrete coordination problem.

## 8. Application Model

### 8.1 Native Mac application lifecycle

Major Tom is a multiwindow macOS application. Closing a browser window is not the same operation as quitting the application.

The application may remain running with no open browser windows. Activating Major Tom from the Dock when it has no open browser windows creates a new browser window. The application must also participate correctly in standard macOS reopen behavior.

### 8.2 Windows and tabs

Major Tom supports multiple browser windows, each containing multiple tabs.

Each tab independently owns:

- Its displayed page and committed URL.
- Its navigation history and current position within that history.
- Its pending navigation, loading progress, and cancellation state.
- Its document scroll position.
- Its page zoom.
- Its document presentation and other page-specific state.

Switching tabs or windows must not transfer or confuse any of this state. Commands and menus that operate on a page act on the active tab of the active window.

New tabs and new windows initially navigate to the configured homepage.

Closing the final tab in a window closes that window. Closing one window does not affect tabs or requests in other windows.

### 8.3 Session restoration

Durable session persistence is required for Major Tom 1.0, though it may be deferred from earlier MVP milestones.

Version 1.0 restores the user's browser session after quitting and relaunching Major Tom, including open windows, tab ordering and selection, committed locations, per-tab back/forward history, applicable scroll positions, and page zoom. Restoration must preserve the distinction between durable committed state and network work that was interrupted by termination.

Settings, trusted server identities, and the user's browsing-history data persist independently of session restoration. User-facing controls for clearing applicable browsing data will be defined before 1.0.

## 9. Navigation Model

### 9.1 Committed and pending state

A tab distinguishes between its displayed, committed page and a pending navigation destination.

Beginning a navigation immediately displays the normalized pending destination in the address field and presents loading progress. The currently committed page remains visible until replacement content or a browser-generated failure page is ready to commit.

### 9.2 Cancellation

While a request is active, the Reload action becomes Stop. Stop must cancel the underlying network work rather than merely hiding its progress.

After cancellation, the previously committed page remains displayed and its URL is restored in the address field. A canceled navigation does not create a history entry.

Closing a tab cancels work owned solely by that tab. Switching away from a tab does not cancel its work; background tabs may continue loading independently.

### 9.3 History mutation

A successful new navigation creates one history entry for the final committed location. Intermediate redirects do not create separate history entries.

Reloading the current page does not create a history entry. Navigating to a new destination after moving backward in history discards the forward branch.

Back and Forward restore the corresponding history entry and its associated page state when available.

### 9.4 Redirects

Redirects update the pending destination shown to the user. The final normalized destination becomes the committed URL when navigation completes.

Redirect loops and excessive redirect chains fail with a Major Tom error page rather than continuing indefinitely.

### 9.5 Failed navigation

A failed navigation replaces the old document with a clearly identified browser-generated error page and commits the attempted final URL. The failure is a navigable tab state: Reload retries it, while Back and Forward continue to operate predictably.

Browser-generated content must be visually and semantically distinguishable from capsule-provided content.

### 9.6 Navigation feedback

Navigation feedback must be immediate and must remain associated with the tab that owns the request. At minimum, the active tab exposes its pending destination, loading state, the ability to stop, and completion or failure. The final visual treatment will follow native macOS conventions and be specified with the browser chrome.

### 9.7 Progressive navigation commitment

Major Tom supports progressive response rendering. A new page may commit once a valid success response header has been received and displayable content begins arriving; the complete response body is not required before the destination replaces the prior page.

If navigation is stopped before the new page commits, the previous page remains committed. If it is stopped after progressive content has committed, the partially received page remains visible and is clearly marked as stopped or incomplete. Partial content is never represented internally as a complete cached response.

If a connection fails after progressive content has committed, Major Tom preserves the received content and presents the failure or truncation state without replacing useful partial content with an unrelated blank error page.

## 10. Streaming Responses

Streaming is a core product behavior, not merely a networking optimization.

### 10.1 Time to first content

For displayable success responses, Major Tom begins presenting content as soon as it has enough response data to do so safely. It does not wait for the entire response body to download.

The renderer updates in bounded batches so progress feels immediate without causing excessive layout work, flicker, lost selection, unstable scrolling, or unnecessary energy use.

### 10.2 Incremental parsing

Text content is decoded and parsed incrementally. Incomplete character sequences, line endings, and Gemtext constructs are retained until enough data arrives to interpret them correctly.

For Gemtext, completed semantic blocks become available to the presentation layer while later content is still arriving. Preformatted blocks and any future inline enhancement syntax must retain correct parser state across network chunks.

### 10.3 Progressive interaction

Already presented content should remain readable, selectable, scrollable, and interactive while later content arrives. Links that have been fully parsed may be used before the response completes.

The browser must avoid disruptive automatic scroll jumps. A reader who has moved away from the growing end of a document remains in control of their position.

### 10.4 Integrity and source preservation

Major Tom retains the exact received bytes alongside incremental parsed state. View Source, Save Page As, caching, completion status, and diagnostics must distinguish complete responses from stopped, truncated, or failed streams.

## 11. Address and Search Field

### 11.1 Unified field

Major Tom uses one field for capsule locations and search queries. Interpretation occurs only when the user submits the field; editing by itself does not navigate, change history, or change the committed page.

### 11.2 Input interpretation

Submitted text is trimmed and interpreted in this order:

1. A valid explicit `gemini://` URL navigates within Major Tom.
2. A probable capsule location without a scheme—such as a hostname, hostname and port, IP address, or host followed by a path—is interpreted as Gemini and normalized with `gemini://`.
3. A valid URL with an external scheme is handed to the appropriate macOS application when that scheme is permitted.
4. Remaining text is treated as a search query and sent to the configured Gemini search provider.

Invalid explicit Gemini URLs produce understandable validation feedback. They are not silently converted into searches.

The exact recognition rules must minimize surprising classification while supporting common capsule-address forms, including local development addresses.

### 11.3 Canonical display

Pending and committed Gemini locations are displayed in a canonical, normalized form. Normalization occurs before a navigation is represented in the field or history.

URL display must preserve information material to the request and must not use deceptive elision. Any future visual simplification of an address must retain a way to inspect and copy its complete canonical value.

### 11.4 Native field behavior

- `Command-L` focuses the field and selects its contents.
- Return submits the edited value.
- Escape abandons the edit and restores the current pending or committed location as appropriate.
- Standard macOS text editing, selection, clipboard, undo, and redo behavior applies.
- Removing focus after submission must not leave a misleading editing or selection state.

### 11.5 Search providers

The initial search-provider choices are Kennedy, TLGS, and a custom Gemini search endpoint. Queries are encoded safely and appended according to the provider's defined URL format.

Changing the configured provider affects future searches only. It does not rewrite history entries.

## 12. Gemini Input Responses

### 12.1 Prompt presentation

A Gemini input response presents the server-provided prompt in a native input interface associated with the requesting tab and window. The input response is an intermediate navigation state and does not create a history entry by itself.

Canceling input abandons the pending navigation and returns cleanly to the previously committed page. Submitting input continues the pending navigation with the response encoded according to the Gemini protocol.

A background tab that reaches an input response must not steal focus or present controls over a different active tab. It indicates that it needs attention and presents its prompt when the user selects it.

### 12.2 Normal and sensitive input

Status `10` presents ordinary visible text input.

Status `11` presents input whose characters are masked. This masking is an optional-entry presentation feature defined by the protocol; Major Tom does not assign status `11` additional URL, history, caching, persistence, or logging semantics.

### 12.3 Editing behavior

The input control supports multiple lines and responds fluidly as content is entered.

- Return submits the input.
- Shift-Return inserts a newline.
- Escape cancels the prompt.
- The control expands vertically as lines are added, up to a suitable maximum height, after which its content scrolls.
- Keyboard focus begins in the input control.
- The prompt and input state are accessible to VoiceOver.

The interface must enforce the Gemini request-size limit based on the encoded request, including the destination URL, delimiter, escaped characters, and line breaks. Invalid or oversized input remains editable and receives clear feedback rather than being truncated silently.

## 13. Client-Certificate Authentication

Major Tom supports self-signed Gemini client certificates for authentication represented by status codes `60` through `69`. Status `60` requests an identity, `61` reports that the offered identity is not authorized, and `62` reports that it is not valid. The interface preserves the capsule-provided message and lets the user choose another valid identity, create one, or remove the rejected approval.

Major Tom creates RSA-2048 certificates signed with SHA-256 and marks them for TLS client authentication. The creation form requires a common name and expiration date and optionally accepts the public subject fields email address, user ID, domain, organization, and country. The interface makes clear that subject fields are public identity data presented to a capsule, not secret profile data.

The manager imports combined, unencrypted PEM client identities containing an X.509 certificate and RSA private key in either order. Users can import an identity from the clipboard, including with Command-V, or choose a file with the native file picker. Before enabling **Import**, Major Tom parses PKCS #1 or PKCS #8 RSA private keys, proves that the private key matches the certificate's public key, and verifies that the stored identity can perform the signature required by TLS. It then displays the certificate with the standard macOS inspector and stores the identity using the same Keychain policy as a locally created identity. When the source was the clipboard, the sheet offers to clear the copied private key after a successful import. Reimporting an existing identity validates or repairs its Keychain items in place so its identifier and capsule approvals remain intact. Encrypted, unsupported, incomplete, and mismatched identities produce specific errors.

**Export Identity…** saves an unencrypted combined PEM file containing the public certificate followed by its RSA private key. Major Tom warns that anyone possessing the file can use the identity before presenting a native save panel. It requests owner-only file permissions where the destination supports POSIX modes, but failure to apply those permissions does not fail an otherwise successful export to a filesystem such as FAT or a network share. Capsule approval scopes are not included in the exported identity.

Private keys and certificates are stored as synchronizable Keychain items. They are never placed in preferences or CloudKit. Public certificate descriptors and activation rules are stored locally and mirrored through the user's private CloudKit database. A newly synchronized rule whose Keychain identity has not arrived on the current Mac is shown as unavailable and is never sent as a partial credential.

An activation rule identifies a Gemini host, effective port, and either the entire capsule or one path and its descendants. Queries and fragments do not affect matching, and a path prefix observes path-segment boundaries. The most-specific matching rule wins. Redirect targets are evaluated independently so approval for one capsule cannot disclose an identity to another capsule.

The client identity is selected before the TLS handshake. A certificate is offered only when a matching user-approved rule exists, its private key is available, and its validity period includes the current time. Because Gemini applications commonly continue authentication across sibling routes after enrollment, the prompt defaults to the whole capsule and offers the challenged path and descendants as an explicit privacy-restricting choice.

The manager at `about:client-certs` displays the selected identity with macOS's standard read-only certificate inspector, with details initially expanded and trust editing disabled. Major Tom supplements the native inspector with local Keychain availability, copy and destructive deletion actions, and a sortable approved-scope table. That table can open a scope in a new tab, change its scope between the entire capsule and that URL and below, or remove the activation rule. Certificate deletion removes the private key and every activation rule after warning that certificate-bound accounts may become inaccessible. Page Info reports the identity actually used for the committed response, or **None**, and can remove the most-specific activation rule for that page with **Stop Using for This Capsule**. **Show Certificate** dismisses Page Info and opens a focused certificate-manager tab with that identity selected.

## 14. Gemini Failure Responses

Major Tom distinguishes capsule-reported Gemini failures from local connection or protocol failures. All failure presentations are clearly identified as browser-generated pages and preserve the exact capsule-provided message when one exists.

### 14.1 Temporary failures

Status codes `40` through `43` and `45` through `49` produce a temporary-failure page containing the exact status code, capsule-provided message, requested URL, and a prominent Retry action.

For status `44` (**Slow Down**), Major Tom presents the server-requested waiting period and disables Retry until that period has elapsed. It does not retry automatically.

### 14.2 Permanent failures

Status codes `50` through `59` produce a permanent-failure page that clearly distinguishes the result from a temporary problem and preserves the exact capsule-provided message.

Reload remains available for permanent failures. The protocol classification informs the user; it does not prohibit an intentional retry.

### 14.3 Other failures

Status codes `60` through `69` use the client-identity-required presentation defined in the client-certificate roadmap section.

Malformed responses, unsupported protocol behavior, TLS failures, and local connection failures produce specific Major Tom diagnostic pages rather than being misrepresented as capsule responses.

## 15. Server Identity and TLS Trust

### 15.1 Trust model

Major Tom uses trust on first use (TOFU) for Gemini server identity. Trust is associated with a capsule host and port and is persisted for later connections.

The trusted identity is the SHA-256 fingerprint of the certificate's Subject Public Key Info (SPKI). It represents the capsule's public key rather than the complete certificate.

A newly issued certificate using the already trusted public key is not an identity change. A certificate containing a different public key is an identity change, regardless of its subject, issuer, signature chain, or presence in a subsequently updated seed list.

The application ships with an initial seed list of trusted identity fingerprints for specific capsules. The seed list provides prior knowledge for those capsules; it is not an allowlist restricting access to the rest of Gemini.

### 15.2 Seeded identity

When a capsule is present in the seed list and the presented identity matches the seeded fingerprint, Major Tom accepts the connection silently.

If a capsule is present in the seed list but presents a different identity, Major Tom treats it as an identity change and requires a user decision.

### 15.3 Unknown capsule

When neither local trust nor the seed list contains an identity for a capsule, Major Tom pauses navigation and presents a clear first-use trust warning.

The warning follows the communication style of Safari's certificate-warning experience: it explains why the connection was paused, identifies the capsule, offers additional certificate and fingerprint details, and provides an explicit way to trust the identity and continue.

The process must not be onerous. It requires a deliberate decision, but it must not bury the continuation action behind confusing language or unnecessary steps.

Accepting the identity stores it as the trusted identity for that host and port and resumes the pending navigation. Declining or canceling leaves the prior page intact and does not establish trust.

### 15.4 Changed identity

When a capsule presents an identity that differs from its locally trusted fingerprint, Major Tom blocks the pending navigation and warns that the capsule's identity has changed.

The warning provides enough information to compare the prior and presented identities and gives the user an explicit opportunity to accept the new identity and continue. Accepting replaces the locally trusted identity while retaining appropriate audit information. Declining leaves the previous trusted identity unchanged.

A changed identity is never accepted silently merely because the newly presented fingerprint appears in a newer seed list.

### 15.5 Trust interface

Trust prompts must clearly distinguish a previously unknown capsule from a changed known identity. They must identify the host and port, summarize the risk in plain language, expose relevant certificate and fingerprint details, provide a safe cancellation path, and provide a direct but deliberate trust-and-continue action.

### 15.6 Certificate dates

An expired or not-yet-valid server certificate produces a certificate-validity warning, even when its public-key fingerprint matches a trusted identity. This warning is distinct from an identity-change warning and allows the user to continue deliberately.

Accepting a certificate-date warning does not replace the trusted public-key fingerprint when that fingerprint already matches.

## 16. Success Content and MIME Types

### 16.1 Gemtext

`text/gemini` responses receive Major Tom's full semantic reading presentation. The renderer preserves document order and meaning while applying the selected content theme and enabled quality-of-life enhancements.

Major Tom supports all standard Gemtext line types: ordinary text, link lines, preformatted toggles and content, headings at all three levels, unordered list items, quotations, and blank lines.

Unicode text and emoji must render correctly using appropriate macOS typography, including color emoji. Byte-order marks and common line-ending forms must not become visible document content.

### 16.2 Other text

Other `text/*` responses are displayed as literal, selectable text using their declared character encoding when supported. Whitespace and line structure are preserved. Unsupported or invalid encodings produce understandable diagnostics without discarding the original bytes.

### 16.3 Images

Common `image/*` responses are displayed directly. An image larger than the available document area initially fits within the view while preserving its aspect ratio. The user can inspect it at its natural size and return to fitted presentation. Scrolling remains available when natural-size content exceeds the viewport.

### 16.4 Other successful content

A successful response with a MIME type Major Tom cannot display produces an informative content page with actions to save the original bytes or open the saved content with an appropriate macOS application when possible.

Unsupported content does not trigger an unsolicited download dialog or write a file automatically.

### 16.5 Titles

For Gemtext, Major Tom examines only the first 15 lines. The first nonempty heading of any level is the document title. If a preformatted block appears before a heading and its opening fence has a nonempty, non-whitespace caption, that caption is used provisionally and is replaced by a later heading. Other content does not prevent a later heading from being found within those 15 lines. If no title is found, Major Tom uses the concise display-title fallback derived from the resource filename or capsule hostname, without treating that fallback as author-provided content.

Document titles, display-title fallbacks, tab titles, window titles, and save-filename suggestions are distinct concepts even when they contain the same text.

## 17. Inline Presentation Enhancements

The initial native release recognizes the following optional inline conventions in otherwise ordinary Gemtext text:

- `*text*` as emphasis.
- `**text**` as strong emphasis.
- Backtick-delimited text as inline code rendered in an appropriate fixed-width font.

These features are enabled by default and controlled independently from automatic image presentation.

Inline recognition does not apply inside fenced preformatted content or to the destination portion of link lines. Delimiters must be balanced and nonempty. Unmatched or ambiguous delimiters remain visible literal text. Exact escaping and nesting rules will be defined conservatively and covered by parser tests.

Copying presented text should copy the human-readable text without synthetic visual decoration. View Source and Save Page As always preserve the original delimiters and bytes.

## 18. Links and External Actions

### 18.1 Primary link behavior

- Click opens a link in the current tab.
- Command-click opens a link in a new background tab.
- Shift-Command-click opens a link in a new foreground tab.
- Shift-click opens a link in a new window.
- Option-click downloads the linked resource.
- Control-click shows the link context menu.
- Middle-click opens a link in a new background tab.
- Explicit external schemes are handed to the corresponding macOS application.

Relative Gemini links are resolved against the response URL that produced the containing document.

### 18.2 Link context menu

The native link context menu provides applicable actions including Open Link, Open Link in New Tab, Open Link in New Window, Copy Link, and Download Linked Resource. Inapplicable actions are omitted or disabled according to normal macOS menu conventions.

### 18.3 Page context menu

The native page context menu provides applicable actions including Back, Forward, Reload Page, Show Page Source, and Save Page As. Back and Forward appear only when their actions are available.

### 18.4 Link feedback

Hovering or focusing a link exposes its destination unobtrusively. Link interaction, context menus, keyboard modifiers, focus indication, and accessibility labels follow macOS conventions.

## 19. Viewing Source, Saving, and Downloads

### 19.1 Show Page Source

Show Page Source displays the exact decoded source for text responses without applying Gemtext or inline enhancements.

The source view uses a fixed-width font and a Safari-style line-number gutter. Long source lines wrap in the source column while retaining one line number. Line numbers are visual decoration and are not included when selecting or copying source text.

Source viewing participates in tab history and clearly identifies the underlying resource. It is unavailable for content without a meaningful text source.

### 19.2 Save Page As

Save Page As writes the original response-body bytes, not rendered output.

The suggested filename follows these rules:

1. Use the final response URL's filename when present.
2. Otherwise use the author-provided document title when present.
3. Otherwise use `untitled`.
4. When the chosen name has no extension, add an appropriate extension derived from the MIME type when known.
5. Sanitize title-derived names only as required for a valid macOS filename.

The native save panel keeps the filename editable.

### 19.3 Linked-resource downloads

Downloading a linked resource retrieves it explicitly and presents a native save panel. Gemini downloads use Major Tom's Gemini networking and TLS trust policy. HTTP and HTTPS downloads use normal platform networking and TLS validation.

Downloads are cancellable, report failure clearly, and stream to bounded storage rather than requiring an unbounded in-memory copy.

## 20. Browser Chrome and Commands

The browser chrome is restrained and content-first while retaining familiar Mac browser controls.

The active tab exposes Back, Forward, Home, the unified address/search field, Reload or Stop, and loading progress. Tab presentation communicates title, selection, loading, attention, and close affordance using native conventions.

Major Tom provides native application menus for File, Edit, View, History, Window, and application-level commands. Menu titles, ordering, enabled state, and keyboard shortcuts track the active window and tab.

The initial command set includes:

- New Tab, New Window, Close Tab, Close Window, Open Location, and Save Page As.
- Standard Undo, Redo, Cut, Copy, Paste, and Select All behavior for the focused control.
- Reload Page, Stop Loading, Show Page Source, Zoom In, Zoom Out, Actual Size, and Find where applicable.
- Back, Forward, Home, Up One Level, and Capsule Root.
- Standard window minimization, zooming, activation, and cycling.

Two-finger horizontal trackpad gestures navigate backward and forward only when the document is at the applicable horizontal boundary. Gestures must not interfere with intentional horizontal scrolling.

Page zoom is maintained independently per tab. Zoom changes document presentation without changing application chrome size.

## 21. Status and Diagnostics

Major Tom exposes useful response information without allowing diagnostics to dominate the reading experience. Available page status includes whether content is live, cached, partial, stopped, or failed; MIME type; received size; and useful connection or download timing.

Browser-generated pages identify themselves clearly and never impersonate capsule content. Diagnostic detail is written for people first, with technical information available when useful for troubleshooting.

## 22. Caching and Browsing Data

Each live tab maintains enough cached source and presentation state to make Back and Forward responsive and to restore relevant page state without unnecessary requests.

Cached entries preserve original bytes, response metadata, final URL, title information, completion state, and sufficient parsed or rendered state to reproduce the page under current settings. Presentation-only changes such as content width update the current document stylesheet; changes that require re-rendering use authoritative cached source rather than previously rendered output.

Incomplete, stopped, or truncated responses are labeled as such and are never silently promoted to complete cached responses.

The MVP may use session-scoped browsing data. Major Tom 1.0 includes durable session restoration and persistent browsing history with appropriate user controls for clearing data.

## 23. Settings and Defaults

The initial settings areas include General, Appearance, Networking, Privacy and Security, and Quality of Life, arranged according to macOS conventions.

Initial configurable values include:

- Homepage.
- Search provider and custom search endpoint.
- Application appearance.
- Content theme.
- Content width, with Narrow as the default.
- HTTP proxy.
- Automatic same-capsule inline images, enabled by default.
- Automatic inline `data:` URI images, enabled by default.
- Inline emphasis, strong emphasis, and inline-code recognition, enabled by default.
- Trusted capsule identities, with details and a Remove Trust action.

Removing trust causes the next connection to that host and port to use the applicable seed or first-use workflow. Settings changes that affect visible content update open documents without requiring another Gemini request.

## 24. Networking Requirements

Major Tom implements Gemini over TCP secured by TLS. It supports the protocol's default port and explicit ports, sends SNI, enforces the Gemini request-size limit, supports cancellation, and detects incomplete responses rather than assuming every closed connection completed successfully.

TLS 1.2 or newer is required. Protocol parsing, status handling, redirects, MIME metadata, character encoding, and body streaming are independent of the document renderer.

Redirect chains are bounded and loops are detected. Timeouts and resource limits use sensible defaults and produce specific diagnostics.

An optional HTTP proxy setting supports Gemini connections through an HTTP proxy. Proxy authentication and additional proxy types are future considerations unless required by the existing supported configuration.

Automatic subresource requests, explicit downloads, and foreground navigations share connection, cancellation, trust, and resource-limit infrastructure while retaining distinct user-visible state.

## 25. Accessibility and Native Quality

All primary functionality is usable with keyboard navigation and VoiceOver. Controls have meaningful labels, state, and focus order. Document semantics expose headings, links, lists, quotations, images, and preformatted content appropriately to assistive technology.

Major Tom respects relevant macOS accessibility settings, including reduced motion, increased contrast, and text legibility. Color is not the sole means of communicating loading, failure, trust, or selection state.

Text selection, spelling and text services where appropriate, context menus, focus rings, drag behavior, clipboard behavior, and standard system commands must feel native rather than simulated.

## 26. MVP and 1.0 Scope

### 26.1 Native MVP

The native MVP includes:

- Native macOS application lifecycle, windows, tabs, commands, and settings.
- Gemini networking with streaming, redirects, input, cancellation, status handling, MIME handling, and proxy support.
- Seeded and user-approved TOFU using public-key fingerprints, including unknown, changed, and certificate-date warnings.
- Gemtext, other text, image, unsupported-content, source, and browser-generated page presentations.
- Unified address and search, per-tab history, live-tab caching, themes, zoom, gestures, status, saving, downloads, and agreed quality-of-life enhancements.

### 26.2 Version 1.0

Version 1.0 additionally requires durable window and tab restoration, durable per-tab navigation state, persistent browsing history, and user-facing browsing-data management.

### 26.3 Planned later

The following are explicitly deferred unless reprioritized:

- Gemini client-certificate authentication.
- Bookmarks or favorites.
- Automatic remote updates to the certificate seed list outside application updates.
- Cross-device synchronization.
- Platforms other than macOS.

## 27. Specification Conventions

The remainder of this specification will distinguish among:

- **Principle:** the reason behind a family of product decisions.
- **Requirement:** behavior that must be present in the native application.
- **Proposed improvement:** a recommended change that still requires product agreement.
- **Open product question:** behavior or scope the product manager must decide.
- **Engineering decision:** an implementation choice owned by engineering.
- **Future consideration:** an idea explicitly outside the currently agreed scope.
- **Non-requirement:** existing behavior or implementation detail that must not be treated as binding.

Important requirements will include observable acceptance criteria. These criteria will describe product outcomes rather than prescribe implementation structure.

Product requirements should remain implementation-neutral unless a particular Apple technology is itself part of the user-facing requirement. Decisions such as the minimum macOS version, document-rendering framework, and use of WebKit or native text layout belong to the later engineering design and must be justified against the completed product specification.
