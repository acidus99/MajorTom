# Content themes

Themes let readers change the feel of a page with a few colors while leaving room
for deeper customization. They are ordinary CSS files, editable outside Major Tom.
[Content Presentation](subsystems/content-presentation.md) owns rendering, source
fidelity, and reading behavior; this document owns the theme experience and authoring
model.

## Theme model

A theme has three commented sections:

1. **Palette:** A small set of colors most people can change to create a coherent theme.
2. **Content colors:** Mappings and derived colors for headings, emphasis, links,
   quotations, captions, and other roles. Built-ins may use additional explicit colors
   here to preserve their original appearance.
3. **Element overrides:** Optional CSS for authors who want more control.

The base presentation provides standard typography, spacing, and interactions.
Semantic HTML under one `main` lets authors target familiar elements with simple
selectors. Theme authors should not need to understand browser internals.

The commented [Light](../../Sources/MajorTomCore/Resources/ThemeTemplates/Light.css)
and [Dark](../../Sources/MajorTomCore/Resources/ThemeTemplates/Dark.css) starters are
the reference for available colors and mappings.

## Appearance and families

Application appearance controls windows and controls. Content Appearance independently
uses Light, Dark, or the system setting. Readers choose either a theme family or
individual Light and Dark themes. Switching modes remembers both sets of choices;
inactive controls remain visible but disabled.

A family is a matched pair declared through shared `@family` metadata, with one Light
and one Dark member. It can be selected with any Content Appearance setting; that
setting chooses the active member. Incomplete or ambiguous pairs remain available
as individual themes, with ambiguity explained rather than silently resolved.

Built-in and Custom families remain separate even when their names match. Copying
both members creates a Custom family without replacing the built-in. Individual
choices accept any theme: a single-appearance theme retains its declared appearance,
while a theme supporting both follows the requested appearance.

New installations use the One family and system content appearance. Existing
installations retain their previous choices.

## Choosing and previewing

Pickers show alphabetized choices on the left and a representative reading preview
on the right. Keep Built-in and Custom separate. Individual themes are grouped by
appearance, with empty folders omitted and unclassified themes outside the folders.
Family previews have Light and Dark tabs, regardless of Content Appearance.

Show the theme's author, description, and usable source link when supplied. The
sample covers headings, prose, inline styles including underline, links, lists,
quotations, preformatted content, and images. Previewing changes only the preview;
Use Theme or Use Family applies the choice, and Cancel preserves the saved choice.
Previews must not navigate or fetch remote content.

## Creating and editing

Create Theme asks for a name and Light or Dark starting colors, then opens a complete
starter in the default external editor. Starters do not appear as built-in themes.
Customize Theme copies a built-in; Edit Theme opens a custom file directly. Copies
preserve appearance and attribution and never overwrite another theme. Open Themes
Folder provides access in Finder.

Saved edits update previews and pages already using the theme. Cancelling a picker
does not undo file creation or external edits. Renaming a display name preserves
selection. Built-in and custom themes with identical names remain distinct.

Imported themes credit their original creator or project and describe Acidus's
adaptation. Original Major Tom themes credit Acidus. Descriptions convey the theme's
feel and identify its source without presenting an adaptation as an official variant.

## Missing choices and guarantees

If a selected file disappears or becomes unusable, select and save an available
replacement. Repair both individual choices, including the inactive one. Prefer
Alucard Classic for Light and Dracula Classic for Dark. For a missing family, prefer
One. Otherwise choose the first available built-in alphabetically, then a custom
choice. If no complete families remain, return to the remembered individual choices;
if no themes remain, use readable system colors. Restoring an old file must not
resurrect its previous selection or re-enable family mode.

Theme changes preserve reading state without fetching the page again. Respect the
reader's width and zoom settings, keep supporting text readable, and provide readable
printing independently of the screen theme. Themes stay self-contained and local;
they cannot fetch remote styles, fonts, or images. Malformed files must be reported
without disrupting browsing.
