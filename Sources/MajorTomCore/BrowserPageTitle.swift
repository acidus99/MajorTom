import Foundation

public enum BrowserPageTitle {
    public static func fallback(for url: URL) -> String {
        let filename = url.lastPathComponent
        if !filename.isEmpty && filename != "/" { return filename }
        return url.host ?? "Major Tom"
    }
}
