# omarime themes — Omarchy-native fcitx5 classicui theme

The candidate window should look like the desktop it lives in: same palette,
same corner radius, same typeface, same selection language. This is a
**generator**, not a static theme — it reads the live sources of desktop
truth and bakes them into a self-contained fcitx5 theme.

## The recipe (decoded from omarchy-shell)

| Element | Source | Token |
|---|---|---|
| Panel fill | `colors.toml` | `background` |
| Panel border | `colors.toml` | `accent` (2px — the omarchy popup signature) |
| Text / candidates | `colors.toml` | `foreground` |
| Preedit converted text | `colors.toml` | `accent` |
| Selected candidate pill | `colors.toml` | `accent` @ 30% fill (= shell `selected-fill-alpha` spirit) |
| Labels (1. 2. 3.) | `foreground` @ 55%, 85% size |
| Page arrows / menu glyphs | `foreground` @ 50% |
| Corner radius | `hyprctl getoption decoration:rounding` — sharp desktops stay sharp |
| Font | `fc-match monospace` — same face as bar & menus |

Preedit is rendered **inside the panel** (`PreeditEnabledByDefault=False` in
`~/.config/fcitx5/config`), so the ugly app-side preedit box never appears and
the whole composition lives in one themed surface.

## Install

Full product (recommended):

```bash
cd ~/work/projects/omarchy_plugins/omarime
./install.sh            # theme + hook + settings backend + shell plugins
./install.sh --undo     # restore pre-install fcitx5 config and remove everything
```

Theme-only development install:

```bash
cd themes
./install.sh
```

After install, every `omarchy theme set …` regenerates the IME theme
automatically (hook: `~/.config/omarchy/hooks/theme-set.d/omarime.sh`).

## Manual use / tuning

```bash
~/.local/share/omarime/themes/omarime-theme                 # regenerate from current palette
~/.local/share/omarime/themes/omarime-theme --theme gruvbox # from a named Omarchy theme
omarime-theme --pill-alpha 40 --radius 8 --size 14          # knobs
omarime-theme --selected accent                             # selected text in accent color
omarime-theme --vertical                                    # vertical candidate list
omarime-theme --dry-run                                     # print plan only
```

All flags: see the header comment in `omarime-theme`.

## How it works

- fcitx5 classicui themes are 9-patch SVG/PNG assets + `theme.conf`
  (schema verified against the installed 5.1.21 binary and
  `src/ui/classic/theme.h`).
- `panel.svg` is a 64×64 tile: rounded rect, accent stroke, background fill;
  its 9-patch margin = radius + border + 4 so corners never stretch.
- `highlight.svg` is the selection pill; alpha is expressed with
  `fill-opacity` because 8-digit hex fills render **black** through the
  gdk-pixbuf SVG loader (verified on this machine).
- classicui caches assets by theme name — a config reload does **not**
  re-read regenerated files, so the generator restarts `omarchy-fcitx5.service`
  (~200 ms) when assets changed.
- fcitx5 writes its in-memory config back on exit; the generator therefore
  stops the service before switching `Theme=` and starts it after
  (same trap as `docs/deployment.md`).

## Visual QA (automated)

`./devshot.sh [text] [out.png]` launches its own `foot`, waits until Hyprland
confirms focus, activates the IME for that window, types the text, and takes a
full screenshot. Inspect with:

```bash
magick out.png -crop 1700x320+1350+50 +repage -resize 260% zoom.png
```

Verified states: short word, long sentence (E6 engine top-1), pagination
chevrons, emoji candidates, vertical list, light palette (catppuccin-latte),
dark palette (retro-82).

## Known notes

- The fcitx panel is **not** a layer-shell surface on this setup (absent from
  `hyprctl layers`), so Hyprland `layerrule` blur cannot target it — moot on
  this desktop (blur off), but remember before promising blur anywhere.
- Tray menu ([Menu] section) is themed with the same assets but not yet
  screenshot-verified — check by right-clicking the fcitx tray icon.
- `ShadowMargin` is parsed but unused by the 5.1.21 input window; drop shadows
  would need the contentMargin == 9-patch-margin trick. Deliberately skipped:
  the desktop runs shadows off.
