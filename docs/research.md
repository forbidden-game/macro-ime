# Research notes

Raw findings from the investigation (2026-02). Machine audit details are in
[PLAN.md §2](../PLAN.md).

## Engine landscape

- **rime-ice 雾凇拼音** (iDvel/rime-ice): the de-facto standard modern Rime
  config. Long-term maintained million-entry 简体 dictionary, monthly releases,
  supports Fcitx5/iBus/Weasel/Squirrel. AUR: `rime-ice-git`,
  `rime-ice-pinyin-git`. Includes emoji, symbols, 中英混输, lua goodies.
- **rime-wanxiang 万象拼音** (amzxyz/rime-wanxiang): "语句流" sentence-flow
  focus;立体词库 + grammar language model (octagram 八股文) → noticeably better
  long-sentence composition. AUR: `rime-wanxiang-updater`. ~4k stars, active Q群.
- Community threads (Zhihu 2025) describe the ecosystem as 雾凇 / 白霜 / 万象
  "百花齐放"; some users stick with ice after trying wanxiang (phrase feel),
  others swear by wanxiang for long sentences → ship ice default, wanxiang opt-in.
- Stock `luna_pinyin` (what this machine had) is universally considered outdated.
- fcitx5-chinese-addons has its own libpinyin-based engine with cloudpinyin;
  not on our critical path but a reference for cloud-candidate UX.

## Toggle / state UX

- fcitx5 native: TriggerKeys (default Ctrl+Space), AltTriggerKeys; per-program
  memory via `ShareInputState=PerProgram` in `~/.config/fcitx5/config`.
- `fcitx5-remote -t` toggles; `-n` queries current IM — enough for bar widgets
  and Hyprland bindings. Richer DBus: `org.fcitx.Fcitx.Controller1`
  (`CurrentInputMethod`, `CurrentUI`, `SelectCandidate`, …) — verified live.
- Prior art: hyprinputswitcher (Go, Hyprland socket → fcitx5-remote) for
  per-app switching; mostly covered natively by ShareInputState.

## Beautiful UI paths

- **classicui theming**: ini + image assets, per-screen DPI on Wayland,
  vertical candidate list supported. Reference:
  https://fcitx-im.org/wiki/Theme_Customization . Existing community themes
  (material-color etc.) prove the pipeline; none follow the desktop theme
  automatically → our generator + `omarchy hook install theme-set` is novel.
- **kimpanel**: DBus UI protocol. Panel owns `org.kde.kimpanel.inputmethod`;
  fcitx5's kimpanel addon (`libkimpanel.so`, present on this machine) hands
  over rendering at runtime and falls back to classicui when absent.
  Implementations today: KDE Plasma addon, Kimtoy, GNOME Shell extension
  (wengxt/gnome-shell-extension-kimpanel — compact JS reference).
  **No Hyprland/Quickshell implementation exists → our opportunity.**
- Wayland notes (fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland): Chromium/Electron
  may need `--enable-wayland-ime` for correct popup positioning without
  kimpanel; XWayland apps have known quirks → test matrix required.

## Omarchy integration surface (verified locally)

- Omarchy 4.0 ships fcitx5 plumbing: `omarchy-fcitx5.service` (user unit,
  Restart=always, starts after graphical-session.target) and
  `/usr/share/omarchy/default/environment.d/10-omarchy-fcitx.conf`.
- Shell plugin kinds: `bar`, `bar-widget`, `overlay`, `panel`, `service`,
  `menu`; OSD/clipboard/image-picker demonstrate always-mounted layer-shell
  overlays inside omarchy-shell with shared theme singleton; IPC via
  `omarchy-shell shell summon <id> '<json>'`.
- User plugins live in `~/.config/omarchy/plugins/<id>/`, hot-reload on save.
- Theme hook point: `omarchy hook install theme-set <script>`.

## Search archive

Full search JSON snapshots kept out of the repo (transient); key links are in
PLAN.md §8.
