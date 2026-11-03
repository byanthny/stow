# appearance

Open **Stow → Settings → Appearance** to pick Stow, Graphite, or Paper, adjust background opacity, and choose separate interface and note fonts. Font menus search installed font names. Sizes are in points. Note fonts also apply to Markdown previews; code keeps its monospaced styling. Changes apply immediately to the board and detached notes and are saved locally.

Presets change the palette and light/dark controls while keeping your font and opacity choices. **Reset** restores every default. **Colors** exposes the palette, including attention, failure, and ready status colors; status labels and symbols still carry meaning independently of color.

Opacity affects background fills, never text or controls. Overlapping card and window backgrounds can appear more opaque than the selected value. macOS **Accessibility → Display → Reduce transparency** keeps backgrounds solid without changing your saved preference. This is plain native window transparency, without a blur engine.

# share a theme

**Export theme…** saves a JSON file. **Import theme…** validates the entire file before applying it; an invalid or unsupported theme leaves your current appearance unchanged. The file contains appearance values only, with no notes, pull requests, account information, or app paths. Themes cannot load code, fonts, plugins, or remote resources.

Start with [graphite.json](themes/graphite.json), or export your current settings and edit the values. Import the file again to apply changes; Stow does not watch external theme files. Themes are self-contained: required fields must be present. The two font-name fields are optional; omitting one uses the system font. Extra JSON keys are ignored for forward-compatible metadata, while unsupported schema versions are rejected.

| field | accepted value |
| --- | --- |
| `schemaVersion` | `1` |
| `name` | 1–80 characters, no control characters |
| `colorScheme` | `dark` or `light` |
| `colors` | required `background`, `surface`, `note`, `text`, `muted`, `amber`, `red`, `green` values as `#RRGGBB` |
| `interfaceFontName`, `editorFontName` | installed font name, or omitted/null for system; maximum 200 characters |
| `interfaceFontSize` | 10–22 points |
| `editorFontSize` | 10–32 points |
| `editorLineHeight` | 1–2 times the font’s line height |
| `backgroundOpacity` | 0.2–1, where 1 is solid |

All numbers must be finite. Imported files are limited to 1 MB. A font missing on the current Mac falls back to the system font while retaining its saved name, so the theme stays portable. Stow does not install fonts.

# manual checks

- Open the board, a detached note, and Settings. Change presets, colors, fonts, sizes, line height, and opacity; verify all open windows update and text stays opaque.
- Select text in a Markdown source editor, change appearance, and verify the selection and source remain intact. Type text, change the font, and undo typing. Preview the same note and check headings, lists, links, and monospaced code.
- Search for and choose an installed font. Import a theme naming an unavailable font and verify readable fallback.
- Export, reset, and reimport; verify the exported appearance is restored. Import malformed JSON, a missing required field, an invalid color, an out-of-range number, and a newer schema; verify the current theme is kept.
- Toggle macOS Reduce transparency. Verify solid backgrounds while it is enabled and restoration of the saved opacity when disabled.
- Quit and relaunch with a custom theme; verify appearance persists alongside unchanged notes and board layout.
