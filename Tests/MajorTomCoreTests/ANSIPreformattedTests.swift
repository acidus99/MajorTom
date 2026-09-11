import XCTest
@testable import MajorTomCore

/// The escape character, spelled out so the test bodies read like the bytes a capsule
/// actually sends.
private let esc = "\u{1B}"

final class ANSISGRParserTests: XCTestCase {
    func testPlainLineIsOneUnstyledRun() {
        let runs = ANSISGRParser.runs(in: "  +---+")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.text, "  +---+")
        XCTAssertTrue(runs.first?.style.isPlain == true)
    }

    func testEmptyLineHasNoRuns() {
        XCTAssertTrue(ANSISGRParser.runs(in: "").isEmpty)
    }

    /// The whole point of the feature: the sequences leave the text, the characters stay.
    func testEscapeSequencesAreRemovedAndTextIsPreserved() {
        let line = "\(esc)[37ms\(esc)[31me\(esc)[32ms\(esc)[0m!"
        let runs = ANSISGRParser.runs(in: line)
        XCTAssertEqual(runs.map(\.text).joined(), "ses!")
        for run in runs {
            XCTAssertFalse(run.text.contains(esc), "an escape reached the displayed text")
        }
    }

    func testRunsSplitAtEverySGRSequence() {
        let runs = ANSISGRParser.runs(in: "\(esc)[31mred\(esc)[32mgreen")
        XCTAssertEqual(runs.map(\.text), ["red", "green"])
        XCTAssertNotEqual(runs[0].style.foreground, runs[1].style.foreground)
    }

    func testStyleAppliesOnlyToTextAfterTheSequence() {
        let runs = ANSISGRParser.runs(in: "before\(esc)[31mafter")
        XCTAssertEqual(runs.map(\.text), ["before", "after"])
        XCTAssertTrue(runs[0].style.isPlain)
        XCTAssertEqual(runs[1].style.foreground, .legacy(1))
    }

    func testResetClearsEveryAttribute() {
        let runs = ANSISGRParser.runs(in: "\(esc)[1;3;4;7;31;44mloud\(esc)[0mquiet")
        XCTAssertFalse(runs[0].style.isPlain)
        XCTAssertTrue(runs[1].style.isPlain)
    }

    /// `<ESC>[m` and `<ESC>[0m` are the same sequence; an omitted parameter means zero.
    func testBareSequenceIsAReset() {
        let runs = ANSISGRParser.runs(in: "\(esc)[31mred\(esc)[mplain")
        XCTAssertTrue(runs[1].style.isPlain)
    }

    func testAttributesDoNotCarryBetweenLines() {
        // No reset at the end: state must still not reach the next line, because ANSI
        // art sets its colors afresh per line and a client that carries them bleeds
        // color into the rest of the block.
        let first = ANSISGRParser.runs(in: "\(esc)[31mred")
        let second = ANSISGRParser.runs(in: "plain")
        XCTAssertEqual(first[0].style.foreground, .legacy(1))
        XCTAssertTrue(second[0].style.isPlain)
    }

    func testIndividualAttributesAreParsed() {
        func style(_ parameters: String) -> ANSIStyle {
            ANSISGRParser.runs(in: "\(esc)[\(parameters)mx")[0].style
        }
        XCTAssertTrue(style("1").isBold)
        XCTAssertTrue(style("3").isItalic)
        XCTAssertTrue(style("4").isUnderlined)
        XCTAssertTrue(style("7").isInverse)
        XCTAssertFalse(style("1;22").isBold)
        XCTAssertFalse(style("3;23").isItalic)
        XCTAssertFalse(style("4;24").isUnderlined)
        XCTAssertFalse(style("7;27").isInverse)
        XCTAssertNil(style("31;39").foreground)
        XCTAssertNil(style("41;49").background)
    }

    func testSixteenColorCodes() {
        func style(_ parameters: String) -> ANSIStyle {
            ANSISGRParser.runs(in: "\(esc)[\(parameters)mx")[0].style
        }
        XCTAssertEqual(style("30").foreground, .legacy(0))
        XCTAssertEqual(style("37").foreground, .legacy(7))
        XCTAssertEqual(style("90").foreground, .legacy(8))
        XCTAssertEqual(style("97").foreground, .legacy(15))
        XCTAssertEqual(style("40").background, .legacy(0))
        XCTAssertEqual(style("47").background, .legacy(7))
        XCTAssertEqual(style("100").background, .legacy(8))
        XCTAssertEqual(style("107").background, .legacy(15))
    }

    func test256ColorAndTruecolor() {
        func style(_ parameters: String) -> ANSIStyle {
            ANSISGRParser.runs(in: "\(esc)[\(parameters)mx")[0].style
        }
        XCTAssertEqual(style("38;5;208").foreground, .palette(208))
        XCTAssertEqual(style("48;5;17").background, .palette(17))
        XCTAssertEqual(style("38;2;10;200;30").foreground, .rgb(red: 10, green: 200, blue: 30))
        XCTAssertEqual(style("48;2;1;2;3").background, .rgb(red: 1, green: 2, blue: 3))
        // Colon-joined form from the T.416 lineage, as libvte and kitty emit it.
        XCTAssertEqual(style("38:5:208").foreground, .palette(208))
        XCTAssertEqual(style("38:2:10:200:30").foreground, .rgb(red: 10, green: 200, blue: 30))
        XCTAssertEqual(style("38:2::10:200:30").foreground, .rgb(red: 10, green: 200, blue: 30))
    }

    func testAttributesAfterAMalformedExtendedColorStillApply() {
        // 9 is not a color kind, so the `1` after it is bold rather than a channel that
        // got swallowed along with the sequence it was not part of.
        let recovered = ANSISGRParser.runs(in: "\(esc)[38;9;1mx")[0].style
        XCTAssertNil(recovered.foreground)
        XCTAssertTrue(recovered.isBold, "the parameter after a bad extended color was lost")
        // An extended color cut short takes only its own fields with it.
        let truncated = ANSISGRParser.runs(in: "\(esc)[38;5mx")[0].style
        XCTAssertNil(truncated.foreground)
        XCTAssertTrue(ANSISGRParser.runs(in: "\(esc)[1;38;2;7mx")[0].style.isBold)
    }

    func testOutOfRangeExtendedColorIsIgnored() {
        XCTAssertNil(ANSISGRParser.runs(in: "\(esc)[38;5;300mx")[0].style.foreground)
        XCTAssertNil(ANSISGRParser.runs(in: "\(esc)[38;2;1;2;999mx")[0].style.foreground)
    }

    func testUnknownSGRAttributesAreIgnoredWithoutLosingTheLine() {
        // 5 is blink and 53 is overline; neither is in the rendered subset, and neither
        // may take the colour set alongside it down with it.
        let style = ANSISGRParser.runs(in: "\(esc)[5;53;31mx")[0].style
        XCTAssertEqual(style.foreground, .legacy(1))
    }
}

final class ANSINonSGRSequenceTests: XCTestCase {
    /// There is no cursor in a static document, so movement and erase sequences have
    /// nothing to act on. They must disappear without leaving marks or breaking runs.
    func testCursorAndEraseSequencesLeaveNoArtifacts() {
        let sequences = [
            "\(esc)[2J",       // erase display
            "\(esc)[H",        // cursor home
            "\(esc)[12;40H",   // cursor position
            "\(esc)[1A",       // cursor up
            "\(esc)[K",        // erase line
            "\(esc)[?25l",     // hide cursor, a private-use parameter
            "\(esc)[s",        // save cursor
            "\(esc)[6n"        // device status report
        ]
        for sequence in sequences {
            let runs = ANSISGRParser.runs(in: "left\(sequence)right")
            XCTAssertEqual(
                runs.map(\.text).joined(),
                "leftright",
                "\(sequence.debugDescription) left an artifact"
            )
            XCTAssertTrue(runs.allSatisfy { $0.style.isPlain })
        }
    }

    /// A non-SGR sequence must not end a run either: the text either side of it has the
    /// same attributes, so it is one run.
    func testANonSGRSequenceDoesNotSplitARun() {
        let runs = ANSISGRParser.runs(in: "\(esc)[31mleft\(esc)[Kright")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "leftright")
    }

    func testStringSequencePayloadsAreRemoved() {
        // OSC 8 hyperlinks and OSC 0 window titles carry a payload that would otherwise
        // print as text.
        let bel = "\u{07}"
        XCTAssertEqual(
            ANSISGRParser.runs(in: "a\(esc)]0;window title\(bel)b").map(\.text).joined(),
            "ab"
        )
        XCTAssertEqual(
            ANSISGRParser.runs(in: "a\(esc)]8;;gemini://example.org\(esc)\\b").map(\.text).joined(),
            "ab"
        )
    }

    func testTwoCharacterAndCharsetEscapesAreRemoved() {
        XCTAssertEqual(ANSISGRParser.runs(in: "a\(esc)7b").map(\.text).joined(), "ab")
        XCTAssertEqual(ANSISGRParser.runs(in: "a\(esc)(Bb").map(\.text).joined(), "ab")
    }

    func testUnterminatedSequenceDoesNotEscapeIntoTheText() {
        XCTAssertEqual(ANSISGRParser.runs(in: "a\(esc)[38;5").map(\.text).joined(), "a")
        XCTAssertEqual(ANSISGRParser.runs(in: "a\(esc)").map(\.text).joined(), "a")
    }

    func testNonASCIIArtCharactersSurviveIntact() {
        let blocks = "\u{2588}\u{2593}\u{2592}\u{2591}\u{1F600}"
        let runs = ANSISGRParser.runs(in: "\(esc)[31m\(blocks)\(esc)[0m")
        XCTAssertEqual(runs.map(\.text).joined(), blocks)
    }
}

final class ANSIColorResolutionTests: XCTestCase {
    func testBoldBrightensTheLegacyColorsAndNothingElse() {
        for index in 0..<8 {
            XCTAssertEqual(
                ANSIColor.legacy(index).resolved(bold: true),
                ANSIColor.legacy(index + 8).resolved(bold: false),
                "bold should select the bright counterpart of legacy color \(index)"
            )
        }
        // A color named through the 256-color palette is exactly that color; bold is a
        // weight, not a brightness, once the author has been that specific.
        XCTAssertEqual(
            ANSIColor.palette(1).resolved(bold: true),
            ANSIColor.palette(1).resolved(bold: false)
        )
        XCTAssertEqual(
            ANSIColor.rgb(red: 40, green: 0, blue: 0).resolved(bold: true),
            ContentThemeColor(red: 40, green: 0, blue: 0)
        )
    }

    func testBrightColorsAreLighterThanTheirDimCounterparts() {
        for index in 1..<7 {
            let dim = ANSIColor.legacy(index).resolved(bold: false).relativeLuminance
            let bright = ANSIColor.legacy(index + 8).resolved(bold: false).relativeLuminance
            XCTAssertGreaterThan(bright, dim, "legacy color \(index + 8) should outshine \(index)")
        }
    }

    func testEachNamedColorLeansTowardsItsName() {
        let red = ANSIColor.legacy(1).resolved(bold: false)
        XCTAssertGreaterThan(red.red, red.green)
        XCTAssertGreaterThan(red.red, red.blue)
        let green = ANSIColor.legacy(2).resolved(bold: false)
        XCTAssertGreaterThan(green.green, green.red)
        let blue = ANSIColor.legacy(4).resolved(bold: false)
        XCTAssertGreaterThan(blue.blue, blue.red)
    }

    func testPaletteCubeAndGrayscaleRamp() {
        // 16 through 231 are a 6x6x6 cube: the first entry is its black corner and the
        // last its white one.
        XCTAssertEqual(ANSIColor.palette(16).resolved(bold: false), ContentThemeColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(ANSIColor.palette(231).resolved(bold: false), ContentThemeColor(red: 255, green: 255, blue: 255))
        // 232 through 255 climb monotonically through gray.
        var previous = 0.0
        for index in 232...255 {
            let gray = ANSIColor.palette(index).resolved(bold: false)
            XCTAssertEqual(gray.red, gray.green)
            XCTAssertEqual(gray.green, gray.blue)
            let luminance = gray.relativeLuminance
            XCTAssertGreaterThan(luminance, previous, "grayscale ramp reversed at \(index)")
            previous = luminance
        }
    }

    func testPaletteIndicesBelowSixteenMatchTheLegacyColors() {
        for index in 0..<16 {
            XCTAssertEqual(
                ANSIColor.palette(index).resolved(bold: false),
                ANSIColor.legacy(index).resolved(bold: false)
            )
        }
    }
}

final class ANSIContrastTests: XCTestCase {
    private let white = ContentThemeColor(red: 255, green: 255, blue: 255)
    private let black = ContentThemeColor(red: 0, green: 0, blue: 0)

    /// The invariant the whole feature rests on: whatever a capsule asks for, on
    /// whichever theme the reader chose, the text can be read.
    func testEveryANSIColorIsReadableOnEveryContentTheme() {
        for theme in ContentTheme.allCases {
            for dark in [true, false] {
                let palette = theme.palette(effectiveDarkAppearance: dark)
                // Both the page and the tinted panel a preformatted block is drawn on.
                for background in [palette.background, palette.codeBackground] {
                    for index in 0...255 {
                        for bold in [false, true] {
                            let authored = ANSIColor.palette(index).resolved(bold: bold)
                            let adapted = ANSIContrast.adapted(authored, on: background)
                            XCTAssertGreaterThanOrEqual(
                                adapted.contrastRatio(against: background),
                                ANSIContrast.minimumRatio,
                                "palette \(index) is unreadable on \(theme.rawValue)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testReadableColorsAreLeftExactlyAsTheAuthorWroteThem() {
        // Lagrange's rule, and the reason a dark theme shows a capsule's own palette:
        // a color that already contrasts is not touched at all.
        let brightYellow = ANSIColor.legacy(11).resolved(bold: false)
        XCTAssertEqual(ANSIContrast.adapted(brightYellow, on: black), brightYellow)
        let deepBlue = ANSIColor.legacy(4).resolved(bold: false)
        XCTAssertEqual(ANSIContrast.adapted(deepBlue, on: white), deepBlue)
    }

    func testLightBackgroundsDarkenAndDarkBackgroundsLighten() {
        let brightYellow = ANSIColor.legacy(11).resolved(bold: false)
        XCTAssertLessThan(
            ANSIContrast.adapted(brightYellow, on: white).relativeLuminance,
            brightYellow.relativeLuminance
        )
        let deepBlue = ANSIColor.legacy(4).resolved(bold: false)
        XCTAssertGreaterThan(
            ANSIContrast.adapted(deepBlue, on: black).relativeLuminance,
            deepBlue.relativeLuminance
        )
    }

    func testAdaptationKeepsTheAuthorsHue() {
        // Red stays red. Shifting a color's hue to make it readable would repaint the
        // art rather than adjust it.
        for index in 0...255 {
            let authored = ANSIColor.palette(index).resolved(bold: false)
            guard authored.hsl.saturation > 0.2 else { continue }
            for background in [white, black] {
                let adapted = ANSIContrast.adapted(authored, on: background)
                XCTAssertEqual(
                    adapted.hsl.hue,
                    authored.hsl.hue,
                    accuracy: 0.02,
                    "palette \(index) changed hue"
                )
            }
        }
    }

    func testAdaptationMovesNoFurtherThanItMust() {
        // The smallest correction that reads: one step back toward the author's own
        // lightness must fail the floor.
        let background = ContentThemeColor(red: 0x28, green: 0x2a, blue: 0x36)
        let authored = ANSIColor.legacy(4).resolved(bold: false)
        let adapted = ANSIContrast.adapted(authored, on: background)
        let (hue, saturation, lightness) = adapted.hsl
        let lessAdapted = ContentThemeColor(
            hue: hue,
            saturation: saturation,
            lightness: lightness - 0.02
        )
        XCTAssertLessThan(
            lessAdapted.contrastRatio(against: background),
            ANSIContrast.minimumRatio
        )
    }

    func testHSLRoundTripsThroughEightBitColor() {
        for index in 0...255 {
            let color = ANSIColor.palette(index).resolved(bold: false)
            let (hue, saturation, lightness) = color.hsl
            let restored = ContentThemeColor(hue: hue, saturation: saturation, lightness: lightness)
            XCTAssertEqual(Int(restored.red), Int(color.red), accuracy: 1)
            XCTAssertEqual(Int(restored.green), Int(color.green), accuracy: 1)
            XCTAssertEqual(Int(restored.blue), Int(color.blue), accuracy: 1)
        }
    }
}

final class ANSIStyleResolverTests: XCTestCase {
    private let palette = ContentTheme.draculaDark.palette(effectiveDarkAppearance: true)

    private func resolver(backgrounds: Bool) -> ANSIStyleResolver {
        ANSIStyleResolver(
            themeForeground: palette.foreground,
            themeBackground: palette.codeBackground,
            rendersBackgroundColors: backgrounds
        )
    }

    /// Lagrange's second rule: a background alone can hide the text drawn over it,
    /// because the author never saw the theme's own text color.
    func testABackgroundWithoutAForegroundIsDropped() {
        let resolved = resolver(backgrounds: true).resolve(ANSIStyle(background: .legacy(4)))
        XCTAssertNil(resolved.background)
        XCTAssertNil(resolved.foreground)
        XCTAssertTrue(resolved.isPlain)
    }

    func testBackgroundsNeedBothAForegroundAndThePreference() {
        let style = ANSIStyle(foreground: .legacy(7), background: .legacy(4))
        XCTAssertNil(resolver(backgrounds: false).resolve(style).background)
        XCTAssertNotNil(resolver(backgrounds: true).resolve(style).background)
        // The foreground still arrives either way.
        XCTAssertNotNil(resolver(backgrounds: false).resolve(style).foreground)
    }

    func testForegroundIsReadableAgainstWhicheverBackgroundItIsDrawnOn() {
        // With backgrounds off the run sits on the theme; with them on it sits on the
        // author's color. Readability is measured against the one that will be there.
        let style = ANSIStyle(foreground: .legacy(0), background: .legacy(0))
        let withoutBackground = resolver(backgrounds: false).resolve(style)
        XCTAssertGreaterThanOrEqual(
            withoutBackground.foreground!.contrastRatio(against: palette.codeBackground),
            ANSIContrast.minimumRatio
        )
        let withBackground = resolver(backgrounds: true).resolve(style)
        XCTAssertGreaterThanOrEqual(
            withBackground.foreground!.contrastRatio(against: withBackground.background!),
            ANSIContrast.minimumRatio
        )
    }

    func testTraitsPassThroughIndependentlyOfColor() {
        let resolved = resolver(backgrounds: false)
            .resolve(ANSIStyle(isBold: true, isItalic: true, isUnderlined: true))
        XCTAssertTrue(resolved.isBold)
        XCTAssertTrue(resolved.isItalic)
        XCTAssertTrue(resolved.isUnderlined)
        XCTAssertNil(resolved.foreground)
    }

    func testReverseVideoSwapsTheAuthorsColors() {
        let resolved = resolver(backgrounds: true)
            .resolve(ANSIStyle(foreground: .legacy(1), background: .legacy(7), isInverse: true))
        XCTAssertEqual(resolved.background, ANSIColor.legacy(1).resolved(bold: false))
        XCTAssertNotNil(resolved.foreground)
    }

    /// Reverse with only a foreground set is the common case, and the swap fills the
    /// other side from the theme — which is what makes it a run with both colors set,
    /// so the background rule above is satisfied rather than side-stepped.
    func testReverseVideoWithOnlyAForegroundStillPaintsABackground() {
        let resolved = resolver(backgrounds: true)
            .resolve(ANSIStyle(foreground: .legacy(1), isInverse: true))
        XCTAssertEqual(resolved.background, ANSIColor.legacy(1).resolved(bold: false))
        XCTAssertGreaterThanOrEqual(
            resolved.foreground!.contrastRatio(against: resolved.background!),
            ANSIContrast.minimumRatio
        )
    }

    func testPlainStyleProducesNoDeclarations() {
        XCTAssertTrue(resolver(backgrounds: true).resolve(ANSIStyle()).css.isEmpty)
    }
}

final class ANSIPreformattedRenderingTests: XCTestCase {
    private let renderer = HTMLDocumentStreamRenderer()

    private func render(
        _ event: GemtextEvent,
        options: HTMLRenderingOptions = HTMLRenderingOptions()
    ) -> String {
        String(decoding: renderer.render(event, options: options), as: UTF8.self)
    }

    func testColorsBecomeInlineStyleRuns() {
        let html = render(.preformattedLine("\(esc)[31mred\(esc)[0mplain"))
        XCTAssertTrue(html.contains("<span style="), "expected a styled run")
        XCTAssertTrue(html.contains("color:#"))
        XCTAssertTrue(html.contains(">red<"))
        XCTAssertTrue(html.contains("plain"))
    }

    /// The acceptance rule: no escape sequence, SGR or otherwise, reaches the document.
    func testNoEscapeCharacterReachesThePreformattedDocument() {
        let lines = [
            "\(esc)[31mred",
            "\(esc)[2J\(esc)[Hcleared",
            "\(esc)]0;title\u{07}text",
            "\(esc)[38;5;208morange"
        ]
        for line in lines {
            for rendersANSIColors in [true, false] {
                let html = render(
                    .preformattedLine(line),
                    options: HTMLRenderingOptions(rendersANSIColors: rendersANSIColors)
                )
                XCTAssertFalse(html.contains(esc), "\(line.debugDescription) leaked an escape")
                XCTAssertFalse(html.contains("[31m"))
                XCTAssertFalse(html.contains("[38;5;208m"))
            }
        }
    }

    func testTurningTheFeatureOffStillStripsTheSequences() {
        let html = render(
            .preformattedLine("\(esc)[31mred"),
            options: HTMLRenderingOptions(rendersANSIColors: false)
        )
        XCTAssertFalse(html.contains("color:#"), "colors were applied with the option off")
        XCTAssertTrue(html.contains("red"))
    }

    func testBackgroundColorsFollowTheirOwnOption() {
        let line = "\(esc)[37;44mpanel"
        XCTAssertTrue(
            render(.preformattedLine(line)).contains("background-color:#"),
            "backgrounds should render by default"
        )
        XCTAssertFalse(
            render(
                .preformattedLine(line),
                options: HTMLRenderingOptions(
                    rendersANSIColors: true,
                    rendersANSIBackgroundColors: false
                )
            ).contains("background-color")
        )
    }

    func testDecodingOptionsWithoutBackgroundPreferenceUsesEnabledDefault() throws {
        let json = Data(#"{"recognizesEmphasis":false}"#.utf8)
        let options = try JSONDecoder().decode(HTMLRenderingOptions.self, from: json)
        XCTAssertFalse(options.recognizesEmphasis)
        XCTAssertTrue(options.rendersANSIBackgroundColors)
    }

    func testTraitsReachTheRunAsFontStyling() {
        let html = render(.preformattedLine("\(esc)[1;3;4;32mstyled"))
        XCTAssertTrue(html.contains("font-weight:bold"))
        XCTAssertTrue(html.contains("font-style:italic"))
        XCTAssertTrue(html.contains("text-decoration:underline"))
    }

    /// Scope rule: ANSI is a preformatted-block feature. An escape in a heading, a
    /// quote or a paragraph is left exactly as the capsule sent it.
    func testOrdinaryGemtextLinesAreNotParsedForANSI() {
        let events: [GemtextEvent] = [
            .text("\(esc)[31mred"),
            .heading(level: 1, text: "\(esc)[31mred"),
            .quote("\(esc)[31mred"),
            .listItem("\(esc)[31mred"),
            .link(destination: "gemini://example.org", label: "\(esc)[31mred")
        ]
        for event in events {
            let html = render(event)
            XCTAssertTrue(html.contains(esc), "\(event) was parsed for ANSI")
            XCTAssertFalse(html.contains("color:#"))
        }
    }

    func testUnstyledPreformattedLineIsUnchangedMarkup() {
        let plain = render(.preformattedLine("  +--+  "))
        XCTAssertTrue(plain.contains("  +--+  "))
        XCTAssertFalse(plain.contains("<span style="))
    }

    func testHTMLInAColoredRunIsStillEscaped() {
        // Capsule content is data. Routing a line through the ANSI parser must not
        // open a path around escaping.
        let html = render(.preformattedLine("\(esc)[31m<script>&"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;&amp;"))
    }

    func testEachLineIsStyledFromScratch() {
        // A block whose first line never resets must not color the second.
        let first = render(.preformattedLine("\(esc)[31mred"))
        let second = render(.preformattedLine("plain"))
        XCTAssertTrue(first.contains("color:#"))
        XCTAssertFalse(second.contains("color:#"))
    }

    func testForegroundsAreAdaptedToTheRenderersOwnTheme() {
        // The same capsule line on a light and a dark theme must produce different
        // colors, both of them readable.
        let line = GemtextEvent.preformattedLine("\(esc)[34mdeep blue")
        for theme in [ContentTheme.draculaDark, .creamsicle] {
            let palette = theme.palette(effectiveDarkAppearance: true)
            let html = String(
                decoding: HTMLDocumentStreamRenderer(contentPalette: palette).render(line),
                as: UTF8.self
            )
            let color = Self.firstColor(in: html)
            XCTAssertNotNil(color, "no color on \(theme.rawValue)")
            XCTAssertGreaterThanOrEqual(
                color!.contrastRatio(against: palette.codeBackground),
                ANSIContrast.minimumRatio,
                "unreadable on \(theme.rawValue)"
            )
        }
    }

    /// Source preservation: the bytes a capsule sent are what View Source and Save
    /// Page As show, escapes included. Only the rendered view drops them.
    func testSourceEscapingLeavesEscapeSequencesIntact() {
        let source = "\(esc)[31mred\(esc)[0m"
        XCTAssertEqual(HTMLDocumentStreamRenderer.escape(source), source)
    }

    private static func firstColor(in html: String) -> ContentThemeColor? {
        guard let range = html.range(of: "color:#") else { return nil }
        let hex = html[range.upperBound...].prefix(6)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return ContentThemeColor(
            red: UInt8((value >> 16) & 0xff),
            green: UInt8((value >> 8) & 0xff),
            blue: UInt8(value & 0xff)
        )
    }
}
