import Foundation

public enum ContentThemeSelection: String, Codable, Sendable {
    case family, individual
}

/// A matched pair stores actual file references as well as its metadata identity.
/// Built-in and custom families with the same name remain separate choices.
public struct ContentThemeFamily: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let isCustom: Bool
    public let lightTheme: String
    public let darkTheme: String

    public var id: String { "\(isCustom ? "custom" : "system")/\(name)" }

    public static let defaultSelection = ContentThemeFamily(
        name: "One", isCustom: false, lightTheme: "system/oneLight.css", darkTheme: "system/oneDark.css"
    )

    public init(name: String, isCustom: Bool, lightTheme: String, darkTheme: String) {
        self.name = name
        self.isCustom = isCustom
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
    }

    public static func catalog(in themes: [ContentTheme]) -> (families: [ContentThemeFamily], errors: [String]) {
        let members = themes.filter { $0.family != nil }
        let groups = Dictionary(grouping: members) { "\($0.isCustom ? "custom" : "system")/\($0.family!)" }
        var families: [ContentThemeFamily] = []
        var errors: [String] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let light = group.filter { $0.appearance == .light }
            let dark = group.filter { $0.appearance == .dark }
            if light.count > 1 || dark.count > 1 {
                errors.append("The \(group[0].family!) family (\(group[0].isCustom ? "Custom" : "Built-in")) has multiple themes for the same appearance. Give each pair a unique @family name.")
            } else if let light = light.first, let dark = dark.first {
                families.append(ContentThemeFamily(name: light.family!, isCustom: light.isCustom,
                                                   lightTheme: light.id, darkTheme: dark.id))
            }
        }
        families.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return (families, errors)
    }

    public static func fallback(in families: [ContentThemeFamily]) -> ContentThemeFamily? {
        families.first { $0.id == defaultSelection.id }
            ?? families.first { !$0.isCustom }
            ?? families.first
    }

    public static func selected(in themes: [ContentTheme], saved: ContentThemeFamily?) -> ContentThemeFamily? {
        let families = catalog(in: themes).families
        return families.first { $0.id == saved?.id } ?? fallback(in: families)
    }
}
