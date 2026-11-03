# appearance

Open **Stow → Settings → Appearance** to choose a preset, colors, background opacity, and separate interface and note fonts. Font menus search installed font names; sizes are in points. Note fonts also apply to Markdown previews, while code keeps its monospaced styling. Changes apply to the board and open notes and are saved locally.

Opacity affects background fills, never text or controls. Overlapping backgrounds can look more opaque than the selected value. macOS **Accessibility → Display → Reduce transparency** keeps backgrounds solid without changing the saved preference. Stow uses native window transparency without blur.

## copy and edit a config

Themes use short `key = value` plaintext configs. Start with [graphite.conf](themes/graphite.conf):

```ini
preset = graphite
font-family = Menlo
font-size = 14
background-opacity = 0.85
```

**Copy config** copies the current appearance as text. **Edit config…** opens a native sheet where you can paste or edit a config and apply it. **Export…** saves a `.conf` file; **Import…** reads one. Import or apply the text again after editing an exported file; Stow does not watch it.

Each config starts from its named preset, then applies the supplied overrides. Without `preset`, the base is `stow`. Omitted settings reset to that base's defaults, rather than keeping values from the previously active theme. A short config is enough; it need not list the entire palette.

Blank lines and full-line comments beginning with `#` are allowed. A `#` inside a color value is part of the hex color, not a comment:

```ini
# a small variation on the light preset
preset = paper
name = Paper notes
note = #FFF9E8
```

## settings

| key | accepted value |
| --- | --- |
| `preset` | `stow`, `graphite`, or `paper`; default `stow` |
| `name` | 1–80 characters, no control characters |
| `color-scheme` | `dark` or `light` |
| `background`, `surface`, `note`, `text`, `muted`, `amber`, `red`, `green` | `#RRGGBB` |
| `font-family`, `ui-font-family` | installed note or interface font name, or `system`; maximum 200 characters |
| `font-size` | note size, 10–32 points |
| `ui-font-size` | interface size, 10–22 points |
| `line-height` | 1–2 times the note font's line height |
| `background-opacity` | 0.2–1, where 1 is solid |

All numbers must be finite. Files are limited to 1 MB. A font missing on the current Mac falls back to the system font while retaining its saved name. Themes do not install fonts or load code, plugins, or remote resources. Exported configs contain appearance settings only, with no notes, pull requests, account information, or app paths.

Invalid or unsupported input keeps the current appearance unchanged. **Reset** restores all defaults. Existing JSON themes remain importable; [graphite.json](themes/graphite.json) is retained as a legacy example. New sharing and exports use plaintext configs.

## manual checks

- Change presets, colors, fonts, sizes, line height, and opacity with the board, a detached note, and Settings open. Check that all update and text stays opaque.
- Select source text, change appearance, and verify selection and source remain intact. Type, change fonts, and undo typing. Check preview headings, lists, links, and code.
- Copy the config, reset, and apply it in the editor. Export and import a `.conf`; verify the appearance returns. Import the legacy JSON example too.
- Apply the short Graphite example after a heavily customized theme. Verify omitted settings return to Graphite defaults. Apply a config without `preset` and verify Stow defaults form its base.
- Test full-line comments and hex colors. Try malformed input, an invalid color, and an out-of-range number; verify the current appearance stays unchanged.
- Import an unavailable font and verify readable fallback. Toggle Reduce transparency and verify solid backgrounds, then restoration of saved opacity.
- Quit and relaunch with a custom theme; verify it persists alongside unchanged notes and board layout.
