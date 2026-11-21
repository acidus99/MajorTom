import Foundation
import XCTest
@testable import MajorTomCore

final class ContentThemeFamilyTests: XCTestCase {
    private func theme(_ filename: String, family: String? = "Reading", appearance: String) throws -> ContentTheme {
        try ContentTheme(id: filename, css: "/*\n@name \(filename)\n@appearance \(appearance)\n\(family.map { "@family \($0)\n" } ?? "")*/")
    }

    private func pair(_ name: String, custom: Bool = false) throws -> [ContentTheme] {
        let source = custom ? "custom" : "system"
        return try [theme("\(source)/\(name)-light.css", family: name, appearance: "light"),
                    theme("\(source)/\(name)-dark.css", family: name, appearance: "dark")]
    }

    func testMetadataAcceptsColonSpellingAndRejectsDuplicateFamilyFields() throws {
        // UserCSS examples may spell @family with a colon, but it remains a single field.
        for field in ["@family Reading", "@family: Reading", "@family:Reading"] {
            let theme = try ContentTheme(id: "custom/test.css", css: "/*\n@name Test\n\(field)\n*/")
            XCTAssertEqual(theme.family, "Reading")
        }
        for field in ["", "@family", "@family: "] {
            XCTAssertNil(try ContentTheme(id: "custom/test.css", css: "/*\n@name Test\n\(field)\n*/").family)
        }
        XCTAssertThrowsError(try ContentTheme(id: "custom/test.css", css: "/*\n@name Test\n@family One\n@family: Two\n*/"))
    }

    func testBuiltInCatalogContainsTenCompleteFamiliesAndLeavesStandaloneThemesAvailable() throws {
        // Resource additions and edits must keep every declared built-in pair usable.
        let themes = ContentTheme.bundled
        let result = ContentThemeFamily.catalog(in: themes)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(Set(result.families.map(\.name)), ["Catppuccin", "Dracula", "GitHub", "Gruvbox", "Monokai", "Nord", "One", "Solarized", "SynthWave ’84", "Tokyo Night"])
        for family in result.families {
            XCTAssertEqual(themes.first { $0.id == family.lightTheme }?.appearance, .light)
            XCTAssertEqual(themes.first { $0.id == family.darkTheme }?.appearance, .dark)
        }
        let dracula = try XCTUnwrap(result.families.first { $0.name == "Dracula" })
        XCTAssertEqual(themes.first { $0.id == dracula.lightTheme }?.name, "Alucard Classic")
        XCTAssertEqual(themes.first { $0.id == dracula.darkTheme }?.name, "Dracula Classic")
        XCTAssertTrue(themes.contains { $0.family == nil })
    }

    func testOnlyUnambiguousPairsQualifyAndCustomFamiliesCannotOverrideBuiltIns() throws {
        // A copied theme cannot replace an original or silently win a duplicate appearance.
        let system = try pair("Reading")
        let custom = try pair("Reading", custom: true)
        let incomplete = try theme("custom/solo.css", family: "Incomplete", appearance: "light")
        let both = try theme("custom/both.css", family: "Adaptive", appearance: "both")
        let result = ContentThemeFamily.catalog(in: system + custom + [incomplete, both])
        XCTAssertEqual(result.families.count, 2)
        XCTAssertEqual(Set(result.families.map(\.id)), ["system/Reading", "custom/Reading"])
        let duplicate = try theme("custom/duplicate.css", appearance: "LIGHT")
        let ambiguous = ContentThemeFamily.catalog(in: system + custom + [duplicate])
        XCTAssertEqual(ambiguous.families.map(\.id), ["system/Reading"])
        XCTAssertEqual(ambiguous.errors.count, 1)
    }

    func testFamilyWorksWithEveryContentAppearanceIndependentlyOfApplicationAppearance() throws {
        // Always Light/Dark still use the selected family; System follows macOS, not the app chrome.
        let themes = try pair("Reading")
        let family = try XCTUnwrap(ContentThemeFamily.catalog(in: themes).families.first)
        for application in ApplicationAppearance.allCases {
            for content in ContentAppearance.allCases {
                let preferences = BrowserPreferences(applicationAppearance: application, contentAppearance: content,
                                                     contentThemeFamily: family)
                for systemIsDark in [false, true] {
                    let selected = ContentTheme.selected(in: themes, preferences: preferences, systemIsDark: systemIsDark)
                    let appearance = content.resolved(systemIsDark: systemIsDark)
                    XCTAssertEqual(selected.appearance, appearance)
                    XCTAssertEqual(selected.theme.id, appearance == .light ? family.lightTheme : family.darkTheme)
                }
            }
        }
    }

    func testSwitchingModesPreservesIndividualAndFamilyChoicesThroughEncoding() throws {
        // Choosing a family must not overwrite a user's independently selected themes.
        let themes = try pair("Reading") + pair("Personal", custom: true)
        let family = try XCTUnwrap(ContentThemeFamily.catalog(in: themes).families.first { !$0.isCustom })
        var preferences = BrowserPreferences(contentAppearance: .light, contentThemeFamily: family,
                                             lightContentTheme: "custom/Personal-dark.css", darkContentTheme: "custom/Personal-light.css")
        preferences.reconcileContentThemes(in: themes)
        XCTAssertEqual(ContentTheme.selected(in: themes, preferences: preferences, systemIsDark: false).theme.id, family.lightTheme)
        preferences.contentThemeSelection = .individual
        XCTAssertEqual(ContentTheme.selected(in: themes, preferences: preferences, systemIsDark: false).theme.id, preferences.lightContentTheme)
        preferences.contentThemeSelection = .family
        preferences = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(preferences.contentThemeFamily, family)
        XCTAssertEqual(preferences.lightContentTheme, "custom/Personal-dark.css")
        XCTAssertEqual(preferences.darkContentTheme, "custom/Personal-light.css")
        XCTAssertEqual(ContentTheme.selected(in: themes, preferences: preferences, systemIsDark: false).theme.id, family.lightTheme)
    }

    func testExistingSettingsKeepTheirAppearanceAndUseIndividualMode() throws {
        // Adding families must not change the appearance of existing installations, even older sparse settings.
        for values: [String: Any] in [[:], ["homepage": "gemini://saved.example/"],
                                     ["contentAppearance": "light", "lightContentTheme": "custom/Personal.css"],
                                     ["contentTheme": "forest"]] {
            let saved = try JSONSerialization.data(withJSONObject: values)
            let preferences = try JSONDecoder().decode(BrowserPreferences.self, from: saved)
            XCTAssertEqual(preferences.contentThemeSelection, .individual)
            XCTAssertEqual(preferences.contentAppearance, values["contentAppearance"] as? String == "light" ? .light : .dark)
            if let light = values["lightContentTheme"] as? String { XCTAssertEqual(preferences.lightContentTheme, light) }
        }
        let new = BrowserPreferences()
        XCTAssertEqual(new.contentAppearance, .system)
        XCTAssertEqual(new.contentThemeSelection, .family)
        let light = ContentTheme.selected(in: ContentTheme.bundled, preferences: new, systemIsDark: false)
        let dark = ContentTheme.selected(in: ContentTheme.bundled, preferences: new, systemIsDark: true)
        XCTAssertEqual(light.theme.family, "One")
        XCTAssertEqual(dark.theme.family, "One")
        XCTAssertEqual(light.appearance, .light)
        XCTAssertEqual(dark.appearance, .dark)
    }

    @MainActor
    func testDeletionPersistsAReplacementFamilyAndItsActualFilenames() throws {
        // Deleting either member must repair both saved family filenames across a restart.
        let suite = "MajorTomTests.Families.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let personal = try pair("Personal", custom: true)
        let family = try XCTUnwrap(ContentThemeFamily.catalog(in: personal).families.first)
        let store = BrowserSettingsStore(defaults: defaults, publishPreferences: { _ in })
        store.preferences.contentThemeFamily = family
        let themes = ContentTheme.bundled + [personal[0]]
        store.reconcileContentThemes(in: themes)
        let reopened = BrowserSettingsStore(defaults: defaults, publishPreferences: { _ in })
        let replacement = try XCTUnwrap(reopened.preferences.contentThemeFamily)
        XCTAssertEqual(replacement.name, "One")
        XCTAssertTrue(themes.contains { $0.id == replacement.lightTheme })
        XCTAssertTrue(themes.contains { $0.id == replacement.darkTheme })
        reopened.reconcileContentThemes(in: themes + [personal[1]])
        XCTAssertEqual(reopened.preferences.contentThemeFamily, replacement)
    }

    func testRemovedDefaultUsesAlphabeticalBuiltInBeforeCustomThenExitsFamilyModeIfNoPairsRemain() throws {
        // Fallbacks must also work when One and eventually all complete pairs are removed.
        let themes = try pair("Zebra", custom: true) + pair("Bravo") + pair("Alpha")
        var preferences = BrowserPreferences()
        preferences.reconcileContentThemes(in: themes)
        XCTAssertEqual(preferences.contentThemeFamily?.name, "Alpha")
        preferences.reconcileContentThemes(in: Array(themes.prefix(2)))
        XCTAssertEqual(preferences.contentThemeFamily?.name, "Zebra")
        preferences.reconcileContentThemes(in: [themes[0]])
        XCTAssertNil(preferences.contentThemeFamily)
        XCTAssertEqual(preferences.contentThemeSelection, .individual)
        XCTAssertEqual(ContentTheme.selected(in: [themes[0]], preferences: preferences, systemIsDark: false).theme.id, themes[0].id)
    }

    func testRenamingFamilyMemberUpdatesSavedFilenameWithoutChangingFamily() throws {
        // Family metadata remains stable even when an author renames a CSS file.
        var themes = try pair("Reading")
        var preferences = BrowserPreferences()
        preferences.reconcileContentThemes(in: themes)
        themes[0] = try theme("system/renamed.css", appearance: "light")
        preferences.reconcileContentThemes(in: themes)
        XCTAssertEqual(preferences.contentThemeFamily?.id, "system/Reading")
        XCTAssertEqual(preferences.contentThemeFamily?.lightTheme, "system/renamed.css")
    }
}
