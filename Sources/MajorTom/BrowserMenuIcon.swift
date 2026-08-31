import Foundation

/// One source of truth for actions that appear in both native context menus and the
/// application menu bar. Keeping the symbol names here prevents the two presentations
/// from drifting apart as either menu is rebuilt.
enum BrowserMenuIcon {
    static let back = "chevron.left"
    static let forward = "chevron.right"
    static let reload = "arrow.clockwise"
    static let showSource = "doc.text.magnifyingglass"
    static let archive = "clock.arrow.circlepath"
    static let save = "square.and.arrow.down"
    static let print = "printer"
    static let newTab = "plus.rectangle.on.rectangle"
    static let newWindow = "macwindow.badge.plus"
    static let download = "arrow.down.circle"
    static let copyLink = "doc.on.doc"

    static let menuBarSymbolByTitle: [String: String] = [
        "Back": back,
        "Forward": forward,
        "Reload Page": reload,
        "Show Page Source": showSource,
        "Check for Previous Versions": archive,
        "Save Page As…": save,
        "Print…": print
    ]
}
