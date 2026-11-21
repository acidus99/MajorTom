import Foundation
import XCTest
@testable import MajorTomCore

final class ContentThemeTests: XCTestCase {
    func testAppearanceLabelsAreCaseInsensitiveAndBothDoesNotAddASuffix() throws {
        // Metadata casing must not reject a theme or duplicate appearance words in the UI.
        for (value, expected, label): (String, ContentThemeAppearance, String) in [
            ("light", .light, "Copper (Light)"), ("LiGhT", .light, "Copper (Light)"),
            ("DARK", .dark, "Copper (Dark)"), ("dark", .dark, "Copper (Dark)"),
            ("both", .both, "Copper"), ("BoTh", .both, "Copper")
        ] {
            let theme = try ContentTheme(id: "custom/copper.css", css: "/*\n@name Copper\n@appearance \(value)\n*/")
            XCTAssertEqual(theme.appearance, expected)
            XCTAssertEqual(theme.name, "Copper")
            XCTAssertEqual(theme.label, label)
        }
    }

    func testSourceLinksAcceptWebPagesAndIgnoreMissingOrUnsafeDestinations() throws {
        // Source is optional metadata, never a request to launch a file or another URL handler.
        let prefix = "/*\n@name Reference\n@appearance dark\n"
        for source in ["https://example.invalid/palette?variant=light#colors", "http://example.invalid/theme", "HTTPS://example.invalid/theme"] {
            let theme = try ContentTheme(id: "custom/reference.css", css: prefix + "@source \(source)\n*/")
            XCTAssertEqual(theme.sourceURL, URL(string: source))
        }
        for source in ["", "/relative/path", "example.invalid/theme", "https://", "file:///tmp/theme.css", "javascript:alert(1)", "mailto:theme@example.invalid", "https://user:password@example.invalid/"] {
            let theme = try ContentTheme(id: "custom/reference.css", css: prefix + "@source \(source)\n*/")
            XCTAssertNil(theme.sourceURL, source)
        }
        XCTAssertNil(try ContentTheme(id: "custom/reference.css", css: prefix + "*/").sourceURL)
    }

    func testMissingOrOtherAppearancesRemainSelectableWithoutAnAppearanceSuffix() throws {
        // Unclassified themes stay in the catalog and follow the requested slot's native appearance.
        for field in ["", "@appearance\n", "@appearance both\n", "@appearance sepia\n", "@appearance automatic\n"] {
            let theme = try ContentTheme(id: "custom/unclassified.css", css: "/*\n@name Unclassified\n\(field)*/")
            XCTAssertEqual(theme.appearance, .both)
            XCTAssertEqual(theme.label, theme.name)
            let preferences = BrowserPreferences(
                contentAppearance: .system, contentThemeSelection: .individual, lightContentTheme: theme.id, darkContentTheme: theme.id
            )
            for systemIsDark in [false, true] {
                let selected = ContentTheme.selected(in: [theme], preferences: preferences, systemIsDark: systemIsDark)
                XCTAssertEqual(selected.theme.id, theme.id)
                XCTAssertEqual(selected.appearance, systemIsDark ? .dark : .light)
            }
        }
    }

    func testRemovedDraculaDarkSelectionsMigrateToClassicInEitherSlot() throws {
        // Removing the old theme must preserve dark rendering rather than fall back to a light slot's default.
        for values: [String: Any] in [
            ["contentTheme": "draculaDark"],
            ["lightContentTheme": "draculaDark", "darkContentTheme": "draculaDark", "contentAppearance": "light"]
        ] {
            let data = try JSONSerialization.data(withJSONObject: values)
            let preferences = try JSONDecoder().decode(BrowserPreferences.self, from: data)
            XCTAssertEqual(preferences.darkContentTheme, "system/draculaClassic.css")
            let selected = ContentTheme.selected(in: ContentTheme.bundled, preferences: preferences, systemIsDark: false)
            XCTAssertEqual(selected.theme.id, "system/draculaClassic.css")
            XCTAssertEqual(selected.appearance, .dark)
        }
        XCTAssertFalse(ContentTheme.bundled.contains { $0.id == "draculaDark" })
    }

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
        let theme = try ContentTheme(id: "custom/Evening.css", css: css)
        XCTAssertEqual(theme.name, "Evening Reading")
        XCTAssertEqual(theme.appearance, .both)
        XCTAssertEqual(theme.metadata["author"], "A Reader")
        XCTAssertEqual(theme.css, css)
        XCTAssertTrue(theme.isCustom)
    }

    func testInvalidOrAmbiguousMetadataIsRejected() {
        for css in [
            "body {} /* @name Late */",
            "/*\n@appearance dark\n*/",
            "/*\n@name Ambiguous\n@appearance dark\n@appearance light\n*/"
        ] {
            XCTAssertThrowsError(try ContentTheme(id: "custom/test.css", css: css))
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
        let theme = try ContentTheme(id: "custom/My Theme.css", css: "/*\n@name My Theme\n@appearance both\n*/")
        let preferences = BrowserPreferences(
            applicationAppearance: .dark, contentAppearance: .system, contentThemeSelection: .individual,
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

    func testEitherSlotCanUseEitherAppearance() throws {
        let light = try ContentTheme(id: "custom/light.css", css: "/*\n@name Light\n@appearance light\n*/")
        let preferences = BrowserPreferences(contentAppearance: .dark, contentThemeSelection: .individual, darkContentTheme: light.id)
        let selected = ContentTheme.selected(in: [light], preferences: preferences, systemIsDark: false)
        XCTAssertEqual(selected.theme, light)
        XCTAssertEqual(selected.appearance, .light)
        for theme in ContentTheme.bundled {
            for slot in [ContentAppearance.light, .dark] {
                let preferences = BrowserPreferences(contentAppearance: slot, contentThemeSelection: .individual,
                    lightContentTheme: theme.id, darkContentTheme: theme.id)
                let selected = ContentTheme.selected(in: ContentTheme.bundled, preferences: preferences, systemIsDark: false)
                XCTAssertEqual(selected.theme, theme)
                XCTAssertEqual(selected.appearance, theme.appearance)
            }
        }
        XCTAssertEqual(preferences.darkContentTheme, light.id)
    }

    func testDiscoveryUsesSourceAndFilenameAndTracksAddedRenamedAndRemovedFiles() throws {
        // Catalog maintenance must never require another hardcoded identifier list.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("palette.css")
        try "/*\n@name Original Title\n*/".write(to: first, atomically: true, encoding: .utf8)
        let system = try XCTUnwrap(ContentTheme.loadBundledThemes(in: directory).themes.first)
        let custom = try XCTUnwrap(ContentTheme.loadCustomThemes(in: directory).themes.first)
        XCTAssertEqual(system.id, "system/palette.css")
        XCTAssertEqual(custom.id, "custom/palette.css")
        XCTAssertFalse(system.isCustom)
        XCTAssertTrue(custom.isCustom)
        var preferences = BrowserPreferences(contentThemeSelection: .individual, lightContentTheme: system.id, darkContentTheme: custom.id)
        preferences.reconcileContentThemes(in: [system, custom])
        XCTAssertEqual(preferences.lightContentTheme, system.id)
        XCTAssertEqual(preferences.darkContentTheme, custom.id)
        try "/*\n@name New Title\n*/".write(to: first, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ContentTheme.loadBundledThemes(in: directory).themes.first?.id, system.id)
        let renamed = directory.appendingPathComponent("renamed.css")
        try FileManager.default.moveItem(at: first, to: renamed)
        let updated = try ContentTheme.loadBundledThemes(in: directory).themes
        preferences.reconcileContentThemes(in: updated)
        XCTAssertEqual(preferences.lightContentTheme, "system/renamed.css")
        XCTAssertEqual(preferences.darkContentTheme, "system/renamed.css")
        try FileManager.default.removeItem(at: renamed)
        let empty = try ContentTheme.loadBundledThemes(in: directory).themes
        preferences.reconcileContentThemes(in: empty)
        XCTAssertEqual(preferences.lightContentTheme, "")
        XCTAssertEqual(preferences.darkContentTheme, "")
        XCTAssertEqual(ContentTheme.selected(in: empty, preferences: preferences, systemIsDark: false).theme.id, "")
    }

    func testMissingSelectionsChoosePreferredThenAlphabeticalBuiltInThenCustom() throws {
        // Defaults refer to files, even if those files' display names or appearances change.
        func theme(_ id: String, _ name: String) throws -> ContentTheme {
            try ContentTheme(id: id, css: "/*\n@name \(name)\n*/")
        }
        let light = try theme(ContentTheme.defaultLightIdentifier, "Z Light")
        let dark = try theme(ContentTheme.defaultDarkIdentifier, "Z Dark")
        let first = try theme("system/first.css", "Alpha")
        let second = try theme("system/second.css", "Bravo")
        let custom = try theme("custom/first.css", "A Custom")
        var preferences = BrowserPreferences(contentThemeSelection: .individual, lightContentTheme: "custom/missing.css", darkContentTheme: "system/removed.css")
        preferences.reconcileContentThemes(in: [custom, second, first, dark, light])
        XCTAssertEqual(preferences.lightContentTheme, light.id)
        XCTAssertEqual(preferences.darkContentTheme, dark.id)
        preferences.reconcileContentThemes(in: [custom, second, first])
        XCTAssertEqual(preferences.lightContentTheme, first.id)
        XCTAssertEqual(preferences.darkContentTheme, first.id)
        preferences.reconcileContentThemes(in: [custom])
        XCTAssertEqual(preferences.lightContentTheme, custom.id)
        XCTAssertEqual(preferences.darkContentTheme, custom.id)
        // Reintroducing deleted files does not change the replacement selections.
        preferences.reconcileContentThemes(in: [light, dark, custom])
        XCTAssertEqual(preferences.lightContentTheme, custom.id)
        XCTAssertEqual(preferences.darkContentTheme, custom.id)
    }

    @MainActor
    func testReplacementSelectionsArePersistedAndSurviveSettingsReload() throws {
        // A deleted file must be replaced on disk, including the inactive appearance slot.
        let suite = "MajorTomTests.ThemeSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserSettingsStore(defaults: defaults, publishPreferences: { _ in })
        store.preferences.lightContentTheme = "custom/deleted.css"
        store.preferences.darkContentTheme = "system/removed.css"
        let available = try ContentTheme(id: "system/remaining.css", css: "/*\n@name Remaining\n*/")
        store.reconcileContentThemes(in: [available])
        let reopened = BrowserSettingsStore(defaults: defaults, publishPreferences: { _ in })
        XCTAssertEqual(reopened.preferences.lightContentTheme, available.id)
        XCTAssertEqual(reopened.preferences.darkContentTheme, available.id)
        let restored = try ContentTheme(id: "custom/deleted.css", css: "/*\n@name Restored\n*/")
        reopened.reconcileContentThemes(in: [available, restored])
        XCTAssertEqual(reopened.preferences.lightContentTheme, available.id)
    }

    @MainActor
    func testLoadingLegacySettingsPersistsFilenameReferences() throws {
        // Migration must update stored settings even when the selected file still exists.
        let suite = "MajorTomTests.ThemeMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"lightContentTheme":"draculaLight","darkContentTheme":"custom:Evening.css"}"#.utf8),
                     forKey: "browser-preferences-v1")
        defaults.set(true, forKey: "browser-preferences-same-capsule-images-disabled-v1")
        _ = BrowserSettingsStore(defaults: defaults, publishPreferences: { _ in })
        let saved = try XCTUnwrap(defaults.data(forKey: "browser-preferences-v1"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(fields["lightContentTheme"] as? String, ContentTheme.defaultLightIdentifier)
        XCTAssertEqual(fields["darkContentTheme"] as? String, "custom/Evening.css")
    }

    func testPreviousIdentifiersMigrateToSourceAndFilenameReferences() throws {
        let cases = [
            "draculaDark": "system/draculaClassic.css", "draculaLight": "system/alucardClassic.css",
            "forest": "system/forest.css", "custom:Evening.css": "custom/Evening.css",
            "system/forest.css": "system/forest.css", "custom/Evening.css": "custom/Evening.css"
        ]
        for (old, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["lightContentTheme": old, "darkContentTheme": old])
            let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: data)
            XCTAssertEqual(decoded.lightContentTheme, expected)
            XCTAssertEqual(decoded.darkContentTheme, expected)
        }
    }

    func testCreatingThemesCopiesBundledStartersWithoutListingThemAsBuiltIns() throws {
        // Starters are authoring resources, not selectable themes; only their name changes on creation.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for appearance in [ContentThemeAppearance.light, .dark] {
            let resource = try XCTUnwrap(Bundle.module.url(
                forResource: appearance.label, withExtension: "css", subdirectory: "ThemeTemplates"
            ))
            let starterCSS = try String(contentsOf: resource, encoding: .utf8)
            let starter = try ContentTheme(id: "template:" + appearance.rawValue, css: starterCSS)
            let name = "Personal $1 \(appearance.label) Theme"
            let url = try ContentThemeAuthoring.create(in: directory, name: name, appearance: appearance)
            let css = try String(contentsOf: url, encoding: .utf8)
            let created = try ContentTheme(id: "custom/" + url.lastPathComponent, css: css)
            XCTAssertEqual(created.name, name)
            XCTAssertEqual(created.appearance, appearance)
            for (key, value) in starter.metadata where key != "name" {
                XCTAssertEqual(created.metadata[key], value)
            }
            let createdEnd = try XCTUnwrap(css.range(of: "*/")).upperBound
            let starterEnd = try XCTUnwrap(starterCSS.range(of: "*/")).upperBound
            XCTAssertEqual(css[createdEnd...], starterCSS[starterEnd...])
            XCTAssertFalse(ContentTheme.bundled.contains { $0.css == starterCSS })
        }
    }

    func testCreatingNamesCannotEscapeTheDirectoryOrOverwriteAnotherTheme() throws {
        // Display names may contain path separators, but filenames stay in Themes.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ContentThemeAuthoring.create(in: directory, name: "../Night:Sky", appearance: .dark)
        let bytes = try Data(contentsOf: first)
        let second = try ContentThemeAuthoring.create(in: directory, name: "../Night:Sky", appearance: .light)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        let result = try ContentTheme.loadCustomThemes(in: directory)
        XCTAssertEqual(result.themes.count, 2)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(Set(result.themes.map(\.name)), ["../Night:Sky"])
        for name in ["", "Injected\n@appearance both", "Line\u{2028}Break", "Name */ body {}", String(repeating: "a", count: 181)] {
            XCTAssertThrowsError(try ContentThemeAuthoring.create(in: directory, name: name, appearance: .dark))
        }
    }

    func testCopyingPreservesMetadataAndEveryByteAfterTheLeadingComment() throws {
        // Arbitrary user CSS, including Section 3 and metadata-like strings, survives duplication.
        let css = "\u{feff} /*\r\n@name Original\r\n@appearance both\r\n@author A Reader\r\n@description Personal CSS\r\n*/\r\n"
            + ":root { --background: #123456; }\r\nmain h1::after { content: '@name Original'; }\r\n"
        let original = try ContentTheme(id: "custom/original.css", css: css)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ContentThemeAuthoring.create(in: directory, name: "Copy $1 /", appearance: .light, copying: original)
        let copiedCSS = try String(contentsOf: url, encoding: .utf8)
        let copy = try ContentTheme(id: "custom/" + url.lastPathComponent, css: copiedCSS)
        XCTAssertEqual(copy.name, "Copy $1 /")
        XCTAssertEqual(copy.appearance, original.appearance)
        XCTAssertEqual(copy.metadata["author"], original.metadata["author"])
        XCTAssertEqual(copy.metadata["description"], original.metadata["description"])
        XCTAssertEqual(copiedCSS.components(separatedBy: "*/").last, css.components(separatedBy: "*/").last)
        XCTAssertEqual(original.css, css)
    }

    func testCustomDiscoveryIsBoundedAndReportsBadFilesIndividually() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let css = "/*\n@name Dracula Classic\n@appearance light\n*/\nbody {}"
        try css.write(to: directory.appendingPathComponent("Personal.CSS"), atomically: true, encoding: .utf8)
        try "invalid".write(to: directory.appendingPathComponent("Broken.css"), atomically: true, encoding: .utf8)
        try css.write(to: directory.appendingPathComponent("Ignored.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 32, count: 1_048_577).write(to: directory.appendingPathComponent("Huge.css"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Directory.css"), withIntermediateDirectories: true)
        let result = try ContentTheme.loadCustomThemes(in: directory)
        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes.first?.id, "custom/Personal.CSS")
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
