import Foundation
import XCTest
@testable import MajorTomCore

final class ContentThemeTests: XCTestCase {
    func testMetadataIsReadOnlyFromTheLeadingComment() throws {
        let css = """
        \u{feff} /* ==UserStyle==
        @name Evening Reading
        @appearance both
        @author A Reader
        ==/UserStyle== */
        /* @appearance light */
        body::before { content: "@name Something Else"; }
        """
        let theme = try ContentTheme(id: "custom:Evening.css", css: css)
        XCTAssertEqual(theme.name, "Evening Reading")
        XCTAssertEqual(theme.appearance, .both)
        XCTAssertEqual(theme.metadata["author"], "A Reader")
        XCTAssertEqual(theme.css, css)
        XCTAssertTrue(theme.isCustom)
    }

    func testInvalidOrAmbiguousMetadataIsRejected() {
        for css in [
            "body {} /* @name Late */",
            "/* @name Missing Appearance */",
            "/*\n@name Invalid\n@appearance automatic\n*/",
            "/*\n@name Ambiguous\n@appearance dark\n@appearance light\n*/"
        ] {
            XCTAssertThrowsError(try ContentTheme(id: "custom:test.css", css: css))
        }
    }

    func testEveryLegacyThemeMigratesWithoutChangingItsAppearanceOrOtherPreferences() throws {
        // Prevent a palette-to-CSS upgrade from resetting the selected theme or homepage.
        for theme in ContentTheme.bundled {
            let data = try JSONSerialization.data(withJSONObject: [
                "contentTheme": theme.id, "homepage": "gemini://keep.example/"
            ])
            let preferences = try JSONDecoder().decode(BrowserPreferences.self, from: data)
            for systemIsDark in [false, true] {
                let selected = ContentTheme.selected(in: ContentTheme.bundled, preferences: preferences, systemIsDark: systemIsDark)
                XCTAssertEqual(selected.theme, theme)
                XCTAssertEqual(selected.appearance, theme.appearance)
            }
            XCTAssertEqual(preferences.homepage, "gemini://keep.example/")
        }
    }

    func testCustomSelectionsRoundTripAndFollowSystemIndependentlyOfApplicationAppearance() throws {
        let theme = try ContentTheme(id: "custom:My Theme.css", css: "/*\n@name My Theme\n@appearance both\n*/")
        let preferences = BrowserPreferences(
            applicationAppearance: .dark, contentAppearance: .system,
            lightContentTheme: theme.id, darkContentTheme: theme.id
        )
        let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
        let light = ContentTheme.selected(in: [theme], preferences: decoded, systemIsDark: false)
        let dark = ContentTheme.selected(in: [theme], preferences: decoded, systemIsDark: true)
        XCTAssertEqual(light.theme, theme)
        XCTAssertEqual(dark.theme, theme)
        XCTAssertEqual(light.appearance, .light)
        XCTAssertEqual(dark.appearance, .dark)
    }

    func testMissingAndIncompatibleThemesFallBackWithoutDiscardingSavedSelections() throws {
        let light = try ContentTheme(id: "custom:light.css", css: "/*\n@name Light\n@appearance light\n*/")
        let preferences = BrowserPreferences(darkContentTheme: light.id)
        for themes in [[], [light]] {
            let selected = ContentTheme.selected(in: themes, preferences: preferences, systemIsDark: false)
            XCTAssertEqual(selected.theme.id, BrowserPreferences().darkContentTheme)
            XCTAssertEqual(selected.appearance, .dark)
        }
        XCTAssertEqual(preferences.darkContentTheme, light.id)
    }

    func testCustomDiscoveryIsBoundedAndReportsBadFilesIndividually() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let css = "/*\n@name Dracula Dark\n@appearance light\n*/\nbody {}"
        try css.write(to: directory.appendingPathComponent("Personal.CSS"), atomically: true, encoding: .utf8)
        try "invalid".write(to: directory.appendingPathComponent("Broken.css"), atomically: true, encoding: .utf8)
        try css.write(to: directory.appendingPathComponent("Ignored.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 32, count: 1_048_577).write(to: directory.appendingPathComponent("Huge.css"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Directory.css"), withIntermediateDirectories: true)
        let result = try ContentTheme.loadCustomThemes(in: directory)
        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes.first?.id, "custom:Personal.CSS")
        XCTAssertEqual(result.errors.count, 2)
        // A custom theme may share a display name with a built-in without replacing it.
        XCTAssertFalse(ContentTheme.bundled.contains { $0.id == result.themes.first?.id })
    }

    func testStylesheetCannotTerminateTheHTMLStyleElement() {
        // Prevent custom CSS comments/strings from escaping into the document shell.
        let css = "/* </StYlE><main id='injected'> */ body { color: red; }"
        let document = String(decoding: HTMLDocumentStreamRenderer().documentStart(themeCSS: css), as: UTF8.self)
        XCTAssertEqual(document.lowercased().components(separatedBy: "</style>").count - 1, 1)
    }
}
