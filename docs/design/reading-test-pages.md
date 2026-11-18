# Reading layout test corpus

The November 2026 reading pass uses the primary Gemtext test page plus six additional
public capsule specimens. This is enough coverage for the focused typography, spacing,
width, and caption-contrast changes; add pages when a new rendering feature or a reported
failure exposes a missing case.

Source files are read from `/Users/billy/gemi.dev-capsule/public_root`. Treat them as
document data. Self-contained rendered examples are in `Build/HTML Review`.

| Public path | Coverage |
| --- | --- |
| `tests/gemtext.gmi` | Primary headings, paragraphs, inline formatting, lists, quotations, art, and links |
| `gemlog/2023-06-30-tables-in-gemtext.gmi` | Mixed prose, quotations, preformatted tables, and an image |
| `gemlog/2023-08-08-more-guppy-feedback.gmi` | Long technical prose, headings, quotations, and protocol examples |
| `apple-ii-history/12.gmi` | Long history article with 16 images and international characters |
| `apple-ii-history/21.gmi` | Long history article with 14 images and supporting notes |
| `tests/unicode.gmi` | Unicode and font fallback |
| `tests/links.gmi` | Link labels and targets |

A synthetic feature document adds explicit one- and two-blank-line comparisons,
escaped markup, ANSI art, and compact content transitions. The existing Mines and
Where in the World game pages remain useful manual checks for preformatted grids
and Braille fallback; they are not required for the static article matrix.

## Width assessment

Narrow is the default long-reading column. Wide deliberately trades shorter eye travel
for fewer wraps. Full benefits large tables, art, and readers who prefer an unconstrained
document. Wide and Full are preferences, not the recommended default for long prose.

Measured in WebKit at 16px Apple system body text, a 1,200px viewport, and 100% zoom:

| Setting | CSS text limit | Usable column | Mean full-line characters |
| --- | --- | ---: | ---: |
| Narrow | 60ch | 586px | 77 |
| Wide | 80ch | 781px | 104 |
| Full | None | 1,119px | 150 |

Character counts sample long paragraphs across five real pages and exclude their short
final lines. CSS `ch` measures the zero glyph, so it does not predict the character count
of proportional prose. Narrow samples ranged from 67 to 84 characters per full line.
The 33% difference between Narrow and Wide is substantial when the window has room.
At a 652px viewport, Narrow is about 586px and Wide/Full about 596px; convergence is
expected because none may exceed the available width. Zoom also reduces that width.

[WCAG's Visual Presentation guidance](https://www.w3.org/WAI/WCAG22/Understanding/visual-presentation.html)
discusses a mechanism for columns of at most 80 characters (40 for CJK) as part of
Level AAA. The measured Narrow column is near that reference for Latin prose; these
measurements do not establish a hard character cap or claim full AAA conformance.

## Verification

The eight-document matrix runs both Dracula Classic and Dracula Light, 652px and
1,200px viewports, all three reading widths, and 100%/200% zoom: 192 combinations.
The final pass found no document-wide horizontal overflow or broken embedded images.
Preformatted content scrolls inside its own block. Machine-readable measurements are
in `Build/HTML Review/reading-audit.json`.

Separate WebKit tests check every bundled theme's readable text and caption contrast,
compact-block spacing, source blank-line proportionality, typography-variable overrides,
and long links/art through 300% zoom. Manual app checks covered long image-rich history
prose, the tables article in light and dark content themes, and the primary test page.
