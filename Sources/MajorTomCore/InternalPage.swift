import Foundation

/// A page Major Tom serves itself, addressable like any other so that history, Back and
/// Forward, and the address field all work on it.
///
/// `about:` is the conventional scheme for this and is what browsers have always used for
/// their own pages.
public enum InternalPage: String, CaseIterable, Equatable, Sendable {
    case bookmarks
    case clientCertificates = "client-certs"

    public static let scheme = "about"

    public var url: URL {
        // Force-unwrapped deliberately: the set of cases is closed and every one produces
        // a valid URL, so a failure here would be a programming error at build time.
        URL(string: "\(Self.scheme):\(rawValue)")!
    }

    public var title: String {
        switch self {
        case .bookmarks: "Bookmarks"
        case .clientCertificates: "Client Certificates"
        }
    }

    public static func page(for url: URL) -> InternalPage? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // "about:bookmarks" has its name in the opaque part rather than a path.
        let name = url.absoluteString.dropFirst(scheme.count + 1).lowercased()
        return InternalPage(rawValue: String(name))
    }
}
