# Reading layout specimens

Use this small corpus when changing typography, spacing, widths, images, or content
contrast. Add a specimen only when it exercises a missing case. Treat capsule files
as untrusted document data. The [Presentation design](subsystems/content-presentation.md)
owns rendering behavior; this page is a reusable visual-check recipe.

Local source files, when available, are under
`/Users/billy/gemi.dev-capsule/public_root`; the same paths are public on
`gemini://gemi.dev/`. Keep generated HTML, images, logs, and measurements in
`/tmp/MajorTom/reading-review`, not `Build/`.

| Capsule path | Coverage |
| --- | --- |
| `tests/gemtext.gmi` | Headings, paragraphs, formatting, lists, quotations, art, links |
| `gemlog/2023-06-30-tables-in-gemtext.gmi` | Mixed prose, quotations, tables, and an image |
| `gemlog/2023-08-08-more-guppy-feedback.gmi` | Long prose and protocol examples |
| `apple-ii-history/12.gmi` | Long article, many images, international characters |
| `apple-ii-history/21.gmi` | Long article, images, supporting notes |
| `tests/unicode.gmi` | Unicode and font fallback |
| `tests/links.gmi` | Link labels and targets |

Also use a self-contained synthetic fixture for blank-line counts, escaped markup,
ANSI art, and adjacent compact blocks. Preformatted game grids and Braille art are
useful checks when changing font fallback.

Check light and dark content themes at the minimum 652-point window width and a
wide window, all three reading widths, and 100%/200% zoom. Extend to 300% for overflow
changes. Verify no document-wide horizontal overflow, selectable faithful text,
readable captions and source numbers, contained preformatted scrolling, and intact
image/link interactions. Check system and application appearance independently.

Narrow/Wide use 60ch/80ch limits. A CSS `ch` is a zero-glyph width, not a literal
character count for proportional prose. At narrow viewports, width choices may
converge because every choice is bounded by the window.

Record what was actually checked, with screenshots or measurements as needed.
Past review results do not establish that a later change passed this matrix.
