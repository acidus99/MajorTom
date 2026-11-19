import Foundation

/// An invocation captures one displayed visit. Later navigation cannot change the
/// bytes, destination, title, or identity used by a native effect.
public struct BrowserPageSnapshot: Sendable {
    public let entryID: BackForwardEntry.ID
    public let url: URL
    public let title: String
    public let documentTitle: String?
    public let mimeType: String
    public let body: Data
    public let completion: PageCompletionState
    public let status: Int?
    public let meta: String
    public let wasCached: Bool?
    public let receivedAt: Date?
    public let serverIdentity: PresentedServerIdentity?
    public let clientCertificate: ClientCertificateDescriptor?
}

/// Pending metadata belongs to its request until that response becomes the page.
struct BrowserResponseMetadata: Sendable {
    var status: Int?
    var meta: String
    var wasCached: Bool?
    var receivedAt: Date?
    var serverIdentity: PresentedServerIdentity?
    var clientCertificate: ClientCertificateDescriptor?
}
