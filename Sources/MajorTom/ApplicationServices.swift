import AppKit
import MajorTomCore

/// Live construction is centralized here. Feature workflows receive their own
/// dependencies; native scene construction selects these application instances.
enum ApplicationServices {
    static let storage = ApplicationStorage(directory:
        MajorTomDataScope.supportFile(named: MajorTomDatabase.filename)?.deletingLastPathComponent())
    static let backForwardCache = storage.session.map(BackForwardCacheStore.init(database:))
    static let contentCache = storage.content.map { ContentCache(database: $0) }
    static let imageLoader = GeminiImageLoader(cache: contentCache)

    @MainActor
    static func presentStorageOpeningFailures() {
        guard !storage.failures.isEmpty else { return }
        let names = storage.failures.map { failure in
            switch failure.store {
            case .durable: "bookmarks, history, and identity metadata"
            case .session: "saved windows and Back/Forward visits"
            case .content: "cached responses"
            case .trust: "trusted capsule identities"
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some Local Storage Is Unavailable"
        alert.informativeText = "Major Tom could not open storage for \(names.joined(separator: "; ")). Changes to affected data may not be saved. Connections requiring unavailable capsule trust will be refused. Quit and try again, or check available disk space and access to application data."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
