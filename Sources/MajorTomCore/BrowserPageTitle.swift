import Foundation

public enum BrowserPageTitle {
    public static func fallback(for url: URL) -> String {
        let filename = url.lastPathComponent
        if !filename.isEmpty && filename != "/" { return filename }
        return url.host ?? "Major Tom"
    }

    /// A page title labelled with its capsule's favicon, as shown on a tab or a
    /// Favorites item.
    ///
    /// The favicon is omitted when the title already opens with it. A capsule that
    /// publishes the same emoji its own headings begin with — Kennedy publishes 🔭 and
    /// titles its pages "🔭 Kennedy: Search Gemini Space" — was otherwise labelled
    /// "🔭  🔭 Kennedy: Search Gemini Space".
    public static func labelled(_ title: String, favicon: String?) -> String {
        guard let favicon, !favicon.isEmpty else { return title }
        guard !title.trimmingCharacters(in: .whitespaces).hasPrefix(favicon) else {
            return title
        }
        return "\(favicon)  \(title)"
    }
}
