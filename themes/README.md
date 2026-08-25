# Macro IME themes — Omarchy-native fcitx5 classicui theme

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
| Font | `Maple Mono NF CN` (fallback: `fc-match monospace`) |

Preedit is rendered **inside the panel** (`PreeditEnabledByDefault=False` in
`~/.config/fcitx5/config`), so the ugly app-side preedit box never appears and
the whole composition lives in one themed surface.

## Install

Full product (recommended):

```bash
cd ~/work/projects/omarchy_plugins/macro-ime
./install.sh            # theme + hook + settings backend + shell plugins
./install.sh --undo     # restore pre-install fcitx5 config and remove everything
```

After install, every `omarchy theme set …` regenerates the IME theme
automatically (hook: `~/.config/omarchy/hooks/theme-set.d/macro-ime.sh`).

## Manual use / tuning

```bash
~/.local/share/macro-ime/themes/macro-ime-theme                 # regenerate from current palette
~/.local/share/macro-ime/themes/macro-ime-theme --theme gruvbox # from a named Omarchy theme
macro-ime-theme --pill-alpha 40 --radius 8 --size 14          # knobs
macro-ime-theme --selected accent                             # selected text in accent color
macro-ime-theme --vertical                                    # explicitly select vertical candidates
macro-ime-theme --horizontal                                  # explicitly select horizontal candidates
macro-ime-theme --dry-run                                     # print plan only
```

Without `--vertical` or `--horizontal`, regeneration preserves the user's
current candidate-layout preference. All flags: see the header comment in
`macro-ime-theme`.

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
