import Foundation

/// A local specimen goes through the same semantic renderer as capsule content.
/// Its links are illustrative; the picker never activates them or fetches resources.
public enum ContentThemePreviewDocument {
    public static func render(theme: ContentTheme, appearance: ContentThemeAppearance, palette: ContentThemePalette) -> String {
        let renderer = HTMLDocumentStreamRenderer(contentPalette: palette)
        let url = URL(string: "gemini://example.invalid/observatory/")!
        let css = theme.stylesheet(for: appearance) + "\n:root { --navigation-height: 0px; }"
        var document = renderer.documentStart(themeCSS: css, baseURL: url, appearance: appearance)
        let introduction: [GemtextEvent] = [
            .heading(level: 1, text: "A Small Observatory"),
            .text("Welcome to a quiet corner of Geminispace. Bring a notebook, make some tea, and look up."),
            .text("Consecutive text lines stay together. Try selecting a few words to see the selection colors."),
            .blank,
            .heading(level: 2, text: "Tonight’s Observations")
        ]
        for event in introduction { document.append(renderer.render(event, baseURL: url)) }
        document.append(renderer.render(.text(
            "A paragraph with **bold text**, *italic text*, and `inline code` keeps the author’s original markers."
        ), baseURL: url))
        let events: [GemtextEvent] = [
            .link(destination: "notes.gmi", label: "Read the observing notes"),
            .link(destination: "gemini://neighbor.invalid/", label: "Visit a neighboring capsule"),
            .link(destination: "https://example.invalid/", label: "A link to the web"),
            .link(destination: "observatory.png", label: "An image of the observatory"),
            .blank,
            .listItem("Bring a warm coat and a thermos of tea."),
            .listItem("Let your eyes adjust to the darkness."),
            .listItem("Take your time: a longer list item wraps naturally and keeps its bullet aligned with the first line."),
            .blank,
            .heading(level: 3, text: "A Note from the Caretaker"),
            .quote("There is no need to recognize every constellation."),
            .quote("Sometimes it is enough to stand still and look up."),
            .quote(""),
            .quote("Leave yourself something to discover tomorrow."),
            .blank,
            .beginPreformatted(altText: "A small observatory beneath the stars"),
            .preformattedLine("       *                  ."),
            .preformattedLine("          .----.       *"),
            .preformattedLine("         /______\\"),
            .preformattedLine("         |  __  |"),
            .preformattedLine("      ___|__||__|___"),
            .endPreformatted,
            .blank,
            .beginPreformatted(altText: "An observing schedule — try collapsing this block"),
            .preformattedLine("TIME    TARGET       NOTES"),
            .preformattedLine("20:00   Moon         Look along the shadow’s edge"),
            .preformattedLine("21:00   Star fields  Turn off the porch light"),
            .endPreformatted,
            .blank
        ]
        for event in events { document.append(renderer.render(event, baseURL: url)) }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="480" height="180" viewBox="0 0 480 180">
        <rect width="480" height="180" fill="#20242b"/>
        <g fill="#e5e8ed"><circle cx="90" cy="40" r="2"/><circle cx="360" cy="55" r="3"/></g>
        <path d="M180 100a60 60 0 0 1 120 0z" fill="#9ccff0"/>
        <path d="M190 100h100v60H190z" fill="#788698"/>
        <path d="M230 125h20v35h-20z" fill="#20242b"/>
        </svg>
        """
        let source = URL(string: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())!
        document.append(renderer.renderInlineImage(resourceURL: source, linkURL: url.appendingPathComponent("observatory.png"),
            altText: "A small observatory beneath two stars", figureIdentifier: "sample-image", fileName: "A quiet night at the observatory"))
        document.append(renderer.documentEnd())
        return String(decoding: document, as: UTF8.self)
    }
}
