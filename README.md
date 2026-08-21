# omarime

A first-class Chinese input experience for Omarchy — best-in-class pinyin
(rime-ice / 万象), effortless hotkey toggling, and a candidate UI that looks
like Omarchy shipped it.

**Status: planning.** See [PLAN.md](PLAN.md) for research, architecture
options, and the roadmap.

## The three promises

1. **Effortless toggle** — `Super+Space` (plus Ctrl+Space), bar indicator 中/EN.
2. **Really good pinyin** — modern maintained dictionaries, long-sentence
   grammar model, fuzzy pinyin, 中英混输, emoji.
3. **Beautiful & native** — theme-aware styling that follows `omarchy theme set`.

## Quick start (once Phase 1 lands)

```bash
git clone <this-repo> && cd omarime
./install.sh          # engine + hotkeys + theme + plugins
```

## Components

| Path | What it is |
|---|---|
| `engine/` | rime schema installer + our overlay patch layer |
| `hypr/` | Hyprland keybinding snippets |
| `plugins/omarime.indicator/` | bar widget: 中/EN state, click to toggle |
| `plugins/omarime.candidate/` | kimpanel-based native candidate window (moonshot) |
| `themes/` | fcitx5 classicui themes generated from the active Omarchy theme |
