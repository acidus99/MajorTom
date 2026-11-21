# Content themes

Major Tom themes are ordinary UTF-8 CSS files. The app loads its base stylesheet first,
then the selected theme, then the print stylesheet. Themes can override variables or use
normal CSS selectors, including nesting. No Sass compilation is required.

This is the theme-authoring reference. [Content Presentation](subsystems/content-presentation.md)
owns rendering and theme behavior; [TODO](TODOs.txt) tracks future theme-management UI.

## Choosing, creating, and editing

Settings > Appearance separates application appearance (windows and controls) from
content appearance (page content). Both offer Use System, Always Light, and Always
Dark. Content Theme offers two mutually exclusive modes:

- **Use theme family** enables a button that opens the matched Light/Dark pair picker.
  Families can be selected with any content appearance; that setting chooses the active member.
- **Choose individual themes** enables the independent Light and Dark theme buttons.
  Each opens the same preview picker containing all built-in and custom themes.

Short explanations remain visible beneath the controls. Inactive mode controls stay
visible but disabled. Switching modes preserves the choices in each mode. New
installations use the built-in One family and Use System content appearance. Existing
settings retain their individual selections and prior content appearance.

Settings and the preview title append `(Light)` or `(Dark)` to the name for
single-appearance files; other appearances add no suffix. Tree rows show only the
theme name because the enclosing folder identifies its appearance. A single-appearance
theme keeps its colors and native control appearance in either individual slot. A
theme declaring `both` follows the slot's Light or Dark appearance.

The individual theme picker has Built-in and Custom sidebar sections, each with
expandable Light and Dark folders. A folder appears only when its section contains a theme with that
appearance, matched case-insensitively. Themes declaring `both`, a different value,
or no appearance remain directly under their section. The selected theme's folder
opens automatically. Empty folders disappear when custom files change or are removed.
Themes are alphabetized by display name within each folder and among unclassified
themes at the section root, using Finder-style localized sorting.

The picker previews a fixed local reading specimen using the real renderer, with a
native underlined sample to demonstrate that color role before underline syntax is
supported. Selecting a row changes only the preview. **Use Theme** saves the choice for the slot that
opened the picker; **Cancel** leaves that choice unchanged. Author and description
metadata appear above the preview. Valid HTTP/HTTPS `@source` metadata appears as a
clickable link that opens in the default web browser. Missing or invalid source
URLs add no link. Links inside the reading preview never navigate or fetch resources.

**Create Theme…** asks for a name and Light or Dark starting colors, then copies the
matching three-section starter and opens the CSS in the default external editor.
Starting colors initially match the slot that opened the picker; either choice is
available from either slot. The starters live in
[`ThemeTemplates/Light.css`](../../Sources/MajorTomCore/Resources/ThemeTemplates/Light.css)
and [`ThemeTemplates/Dark.css`](../../Sources/MajorTomCore/Resources/ThemeTemplates/Dark.css).
Creation fills in the name and preserves the rest of the selected resource. These
resources are separate from the built-in theme catalog and never appear in the picker.

**Customize Theme…** creates a copy of a built-in, with an editable name suggested from its original name
and a local date/time stamp. **Edit Theme…** opens a custom file directly. The list's
**Duplicate Theme…** context-menu action can copy either kind of theme. Copies retain
all CSS and metadata except the display name. Filename collisions produce a unique
filename without overwriting another theme.

Saving an external edit refreshes the preview and any tabs already using that file.
Both in-place writes and atomic file replacement are supported. Canceling the picker
does not undo file creation or edits. Renaming the display name preserves selection;
renaming the file changes its identity. Selections are stored as
`system/<filename>.css` or `custom/<filename>.css`, so identical filenames in the two folders remain distinct. Built-ins are discovered from
the bundled CSS directory, without a separate identifier catalog. When a selected file
disappears, both selection slots are checked and Settings is updated immediately to
reference an existing replacement: `system/alucardClassic.css` for Light and
`system/draculaClassic.css` for Dark. If the preferred default is unavailable, use the
first built-in alphabetically by display name, then the first custom theme if no
built-ins remain. Restoring the removed file does not restore its old selection.
If no theme files remain, clear the saved references and use the base stylesheet's
native system colors until a theme becomes available. Unreadable files and malformed
metadata are reported in Appearance settings. Files must be no larger than 1 MB; subdirectories, hidden files, and symbolic
links are not themes.

**Open Themes Folder…** in the theme picker opens the custom CSS folder in Finder. The production
folder is `~/Library/Application Support/Major Tom/Themes`; development builds use
`Major Tom Development/Themes`. Sandboxed builds resolve Application Support inside
the app container. Use the Finder button rather than relying on a particular path.
Built-in files stay in the app bundle. Custom files and Appearance settings stay
local to this Mac.

## Theme families

Optional `@family Name` metadata links files without a separate application registry.
`@family: Name` is also accepted. Family names are trimmed and matched exactly; the
picker displays the metadata name. Built-in and custom families are separate sidebar groups,
so identical family names cannot replace one another across the two sources. Each
selectable family requires exactly one `light` and one `dark` member, matched by the
case-insensitive `@appearance` field. Standalone themes and incomplete pairs remain
available for individual selection. Duplicate members for one appearance exclude
that family from the picker and produce an explanatory warning.

The family picker shares its native split-view layout, metadata display, preview
WebKit component, and reading specimen with the individual theme picker. The left
sidebar lists family names alphabetically under Built-in and Custom. The right pane
has Light and Dark tabs showing the corresponding CSS, author, description, and
source link. Highlighting a family changes only these previews. **Use Family** applies
the pair; **Cancel** leaves saved choices unchanged. Both members must resolve before
Use Family becomes available. Either preview tab is available regardless of Content
Appearance. The two picker windows maintain independent preview selections.

Settings remembers the family name, built-in/custom source, and both actual
`system/<filename>.css` or `custom/<filename>.css` references, separately from the
individual choices. Renaming a member file updates the family's saved reference if
the same complete family still exists. Removing a member, changing its metadata, or
introducing a duplicate can make the selected family unavailable. Replace and save
that selection with the built-in One family, then the first built-in family
alphabetically, then the first custom family. Restoring the old file does not restore
its previous selection. If no complete families remain, clear the saved family and
switch to individual mode using its repaired file choices. New families do not
subsequently change that mode automatically.

The ten built-in families are Catppuccin, Dracula (Alucard Classic and Dracula
Classic), GitHub, Gruvbox, Monokai, Nord, One, Solarized, SynthWave ’84, and Tokyo
Night. The five original standalone themes stay available individually. Custom
copies preserve family metadata: copying both members makes a separate Custom
family, while copying one member alone does not override the built-in family.
Family selection and custom files stay local to this Mac.

## Metadata

The first CSS comment must contain `@name`. Appearance, family, and other metadata are optional:

```css
/*
@name Evening Reading
@family Evening
@appearance dark
@author Your Name
@description A quiet theme for reading.
@source https://example.invalid/themes/evening
@version 1.0.0
@license MIT
*/

/* Page background, ordinary text, and links for evening reading. */
:root {
  --background: #202530;
  --text: #eef0f5;
  --link: #9bdcff;
}
```

`@appearance` recognizes `light`, `dark`, or `both`, case-insensitively. Missing or
unrecognized values leave a theme unclassified; like `both`, its native controls
follow the requested slot, and its CSS controls the colors. `@name` is the display
name, so it may contain spaces. Custom names are shown as written; appearance
words are not stripped from user-authored names. Author, description, and an optional
web source link are displayed in the picker; other metadata fields are optional
descriptive metadata. Duplicate fields are rejected. Field names are case-sensitive.
This is Major Tom's metadata convention,
inspired by UserCSS, rather than an implementation of the full UserCSS format.

## Supporting both appearances

Major Tom sets `data-appearance="light"` or `data-appearance="dark"` on the document's
`html` element and supplies the matching CSS `color-scheme`. Use that attribute rather
than `prefers-color-scheme`, which follows the system and cannot express a reader's
explicit content appearance choice.

```css
/*
@name Day and Night
@appearance both
*/

/* Light content colors for the dual-appearance theme. */
:root {
  --background: #faf8f2;
  --text: #242424;
  --link: #005a9c;
}

/* Dark content colors selected by Major Tom. */
:root[data-appearance="dark"] {
  --background: #202530;
  --text: #eef0f5;
  --link: #9bdcff;
}
```

The `both` metadata value requires CSS for both appearances. Single-appearance themes
retain their declared appearance regardless of the slot. Light and Dark selections
can use the same file or different files.

## Three-section authoring contract

Section comments are for readers, not a file format that Major Tom parses or rewrites.
Every generated starter contains the complete palette and content-color relationships,
so authors do not need to inspect the base stylesheet. CSS evaluates the relationships
on each save; no compilation or app-side expansion is required.

The bundled catalog includes light and dark variants of GitHub, One, Monokai,
Solarized, Gruvbox, Nord, Tokyo Night, and SynthWave ’84, plus Catppuccin Latte/Mocha
alongside Alucard Classic, Dracula Classic, and the original Major Tom themes.
Alucard Classic uses the official light palette from the Dracula project. Previous
selection identifiers migrate to their source/filename references. Slate and Copper preserves the original custom
theme's neutral headings and emphasis, warm copper links and decoration, and native
selection colors in the three-section format. The original custom file stays untouched.
Each variant is a separate single-appearance CSS file so either selection slot can
choose it directly.

Adapted themes describe their feel in the first description sentence and attribute
the upstream template with “Adapted by Acidus” in the second. Imported palettes credit
their original creator or project in `@author`; original Major Tom palettes and our
new light interpretations credit Acidus. Their `@source` metadata identifies the palette
reference. The light variants of Monokai, Nord, and SynthWave ’84 are original
interpretations rather than official upstream versions. Monokai (Light) borrows the
warm-neutral direction of Monokai Pro Light; Nord (Light) combines Nord's Snow Storm
surfaces with the community OneNord Light accents; SynthWave ’84 (Light) pairs pink-white
surfaces with magenta, cyan, and gold. Accent brightness and supporting text are
adjusted in Section 2 for reading contrast, rather than copying syntax-token roles
directly into prose. These themes leave the standard element layout intact.

### 1. Palette

- `--background`: Whole document canvas
- `--text`: Main text color used by the mappings below
- `--secondary-text`: Supporting text color
- `--link`: Main link color
- `--accent`: Decorative color and optional emphasized text

### 2. Content colors

These variables describe the actual presentation roles. Starters map them to the
palette or derive them with `color-mix()`. Authors may replace any expression with a
specific color. Built-in themes use additional explicit colors here to preserve their
individual palettes; editing Section 1 need not change those independent colors.

- `--body-text`: Ordinary paragraphs and list-item text
- `--heading-text`: H1, H2, and H3 text
- `--bold-text`, `--italic-text`: `strong` and `em` text
- `--underline-text`: `u` text and its matching underline; defaults to `--text`
- `--link-text`, `--link-hover-text`: Links and hovered/focused links
- `--quote-text`, `--quote-background`, `--quote-border`: Quotation text, background,
  and border
- `--caption-text`: Preformatted descriptions, image captions, link hints, source
  numbers
- `--list-marker`: Native list bullets
- `--pre-text`, `--pre-background`: Preformatted text and its background
- `--inline-code-text`, `--inline-code-background`: Inline code text and background
- `--selection-text`, `--selection-background`: Selected text and its background
- `--focus-ring`: Keyboard focus outlines
- `--danger-text`: Generated error headings and interrupted-response borders

Existing color names remain supported as fallback inputs: `--foreground`, `--muted`,
`--surface`, `--heading`, `--strong`, `--emphasis`, `--code`, `--caption`, `--blockquote`,
`--quote-surface`, `--selection`, `--selection-foreground`, and `--danger`.
Explicit new content-role values take precedence over those legacy fallbacks.

Every bundled theme and the new-theme starter map `--underline-text` to `--text`
in Section 2. The base stylesheet supplies a matching underline for `u`; authors
can change its text color through that mapping. This CSS role is available for the
planned inline underline enhancement; it does not add underline syntax recognition.

### 3. Element overrides

All converted Gemtext appears under one `main`. Use ordinary native tags, with CSS
nesting if desired:

```css
main {
  h1 { font-weight: 600; }
  blockquote { border-radius: 0 .4rem .4rem 0; }
  pre { padding: 1rem; }
}
```

Text uses `p`, headings use `h1`–`h3`, and standalone links are direct `main > a`
children. Emphasis uses `strong`, `em`, and inline `code`, retaining author markers.
Consecutive list items share `ul`/`li`. Quoted lines share `blockquote`/`p`; empty
quoted lines separate paragraphs. Blank Gemtext lines emit ordinary `br` elements.
Preformatted blocks use `details`/`summary`/`pre`. Text is raw escaped text except for
ANSI-styled runs, which use spans. Images use `figure`, linked `img`, and `figcaption`.
There are no generic line wrappers or custom elements.

Use `.link-hint` for decorative destination glyphs, `a.image-link` for expandable
image candidates, and `ul > li::marker` for list bullets. `details[open]` identifies
expanded preformatted blocks. The optional `.is-unlabelled` summary marks a fallback
description; interaction scripts add `.is-multiline` to multiline disclosures and
`.is-image-pending`/`.is-loading` to image links. Internal `data-mt-*` attributes and
generated IDs belong to browser interactions rather than the authoring contract.

Generated body classes are `.gemtext-page`, `.source-page`, `.plain-text-page`,
`.image-page`, `.message-page`, and `.history-page`. Source uses `.source-page ol`
with native line numbers. Interrupted responses use `.incomplete`; standalone image
zoom controls use `.image-frame` and `.image-toggle`. Old redundant selectors such as
`.link-line`, `.has-hint`, `.preformatted`, `.source-lines`, and `.message-details` are
replaced by the native structure above.

Base styles occupy a lower-priority cascade layer. Ordinary theme rules can override
them with simple tag selectors; matching the base selectors' specificity is unnecessary.

Every CSS rule in bundled stylesheets has a comment describing its content or interaction.
Colors are declared first, followed by document layout, typography, and component sections.
The root `--navigation-height` layout variable reserves space for native app chrome;
standalone review exports set it to zero.

Explicit content width and zoom settings are applied after theme styles. Print styles
provide a light, readable printed page. Keep normal theme rules low in specificity and
avoid `!important` so these reading controls continue to work as expected.

Themes style presentation only. They do not alter received source bytes, View Source,
or saved output. The document's resource policy blocks external stylesheets, web fonts,
and remote images from CSS; use installed fonts and self-contained styles. WebKit
ignores invalid CSS declarations normally. The native background and ANSI contrast
adapter sample renderer-generated markup and use computed solid body background,
main text, and preformatted colors; gradients or styling that depends on individual
capsule content may have different backgrounds at different points.

Default typography is the 16px macOS system font (San Francisco) at 1.4 line height.
H1, H2, and H3 use 32px, 28px, and 22px respectively at 100% zoom. H2 headings use
semibold weight (600) for a calmer subsection hierarchy.
Each source blank line retains its own vertical space. Directly adjacent headings,
quotes, and art receive a modest gap when no source blank line separates them.
The default reading width is 60ch; Wide is 80ch; Full has no width limit. Side gutters
shrink with the viewport.
Preformatted content uses `ui-monospace` (SF Mono on macOS) at 14px/1.4, with system
fallback for unsupported characters. Kerning and ligatures are disabled for art.
Custom styles cannot fetch remote fonts.

Typography variables (all declared together at the top of `Base.css`):

- `--body-font`: Reading face; default: macOS system stack.
- `--body-size`: Base size; default: `16px`.
- `--body-leading`: Unitless body line height; default: `1.4`.
- `--mono-font`: Code, art, and source face; default: macOS system monospace stack.
- `--mono-size`: Art/source size; default: `0.875rem`.
- `--mono-leading`: Art line height; default: `1.4`.
- `--h1-size`, `--h2-size`, `--h3-size`: Heading sizes; default: `2rem`, `1.75rem`,
  `1.375rem`.
- `--heading-leading`: Heading line height; default: `1.25`.
- `--caption-size`: Supporting text size; default: `0.82rem`.
- `--reading-width`, `--wide-reading-width`: Content width excluding gutters; default:
  `60ch`, `80ch`.
- `--page-gutter`: Responsive side padding; default: `clamp(1rem, 3vw, 2rem)`.

`--caption-text` in the bundled themes blends text toward secondary text. Dracula
Classic retains the official comment color `#6272a4` as its secondary palette value;
its captions use a 40% text / 60% secondary-text blend to stay readable on both
document and source-hover surfaces. All bundled caption roles are verified at 4.5:1
or better. Motion behavior is unchanged.
