# omarime — A first-class Chinese input experience for Omarchy

> Omarchy + Rime + IME. Chinese users deserve a REALLY GOOD keyboard.

Status: **planning** · Target: Omarchy 4.x (Hyprland + Quickshell shell) · Date: 2026-02

---

## 1. Vision

Three promises:

1. **Effortless toggle** — English ⇄ 中文 with one hotkey, a bar indicator that
   always tells you which mode you're in, and optional per-app memory.
2. **Best-in-class pinyin** — modern maintained dictionaries, long-sentence
   grammar model, fuzzy pinyin, 双拼, 中英混输, emoji, per-program state.
3. **Beautiful, native UI** — candidate window and indicators that look like
   they shipped with Omarchy: theme-aware colors, rounded corners, blur,
   smooth animations. Not a foreign body on the desktop.

## 2. Current state (audited on this machine)

| Component | Status |
|---|---|
| fcitx5 5.1.21 + fcitx5-gtk/qt | ✅ installed, `omarchy-fcitx5.service` user service (Omarchy ships this) |
| env vars (`QT_IM_MODULE`, `XMODIFIERS`, …) | ✅ `/usr/share/omarchy/default/environment.d/10-omarchy-fcitx.conf` |
| rime engine | ✅ fcitx5-rime 5.1.14, librime 1.17 |
| rime schemas | ⚠️ only stock `luna_pinyin` — the "1990s" experience. This is the gap. |
| kimpanel addon | ✅ `libkimpanel.so` present → external candidate UI is possible |
| fcitx5 DBus controller | ✅ verified live: `org.fcitx.Fcitx.Controller1` exposes `CurrentInputMethod`, `CurrentUI`, candidate selection, config get/set |
| Omarchy plugin kinds | `bar`, `bar-widget`, `overlay`, `panel`, `service`, `menu` — OSD/clipboard prove always-mounted layer-shell overlays work inside `omarchy-shell` |
| Toggle hotkey | ❌ nothing bound yet; fcitx5 default Ctrl+Space unconfigured |

**Conclusion:** plumbing exists end-to-end. What's missing is exactly our three
promises: a great schema, hotkey UX, and a beautiful face.

## 3. Research findings

### 3.1 Engine landscape (the "REALLY GOOD pinyin" part)

Two viable paths, both built on Rime (engine is already installed):

| | **rime-ice 雾凇拼音** (iDvel) | **rime-wanxiang 万象拼音** (amzxyz) |
|---|---|---|
| Stars / activity | ~10k+, monthly dictionary releases | ~4k+, very active |
| Philosophy | curated million-entry dictionary, out-of-box | "语句流" sentence-flow: optimized dicts + **grammar language model (octagram)** for long-sentence accuracy |
| Long sentences | good | best-in-class (language model) |
| Extras included | emoji, symbols, 中英混输, v-mode, calculator lua, 简繁 | same class + tonal/shuangpin variants, updater tool |
| Install | AUR `rime-ice-git` / `rime-ice-pinyin-git`, or git clone deploy | AUR `rime-wanxiang-updater`, or release zip deploy |
| Risk | none notable | heavier deploy; some users prefer ice's phrase feel |

Community consensus (Zhihu/CSDN 2025): these two are the state of the art;
stock luna_pinyin is what people flee from. **Decision: default = rime-ice,
wanxiang as opt-in profile.** Both share the same patch layer we write once
(fuzzy pinyin options, Shift behavior, per-program memory…).

Must-have features checklist (each maps to concrete config work):

- [ ] 全拼 + optional 小鹤双拼/自然码 profiles
- [ ] 模糊音 (z/zh, c/ch, s/sh, n/l, …) as toggles
- [ ] 中英混输 (type `wifi` get wifi), emoji in candidates, symbol input
- [ ] Long-sentence composition (grammar model for wanxiang; ice's dict for default)
- [ ] Per-program input-state memory → fcitx5 `ShareInputState=PerProgram`
- [ ] Shift behavior sane (user already patched `ascii_composer` to noop — keep)
- [ ] Candidate count / vertical list / font size configurable
- [ ] User dict sync (`rime sync`) documented
- [ ] 快符/日期/计算器 lua goodies from the chosen schema

### 3.2 UI landscape (the "BEAUTIFUL" part)

Options ranked by effort:

**A. Classic UI theme (fcitx5 native window, restyled)** — fcitx5 has an ini +
image theme engine. We generate a theme from the *active Omarchy theme's*
palette (read from `~/.config/omarchy/themes/<active>/`), rounded corners,
Sarasa/Noto CJK font, blur-friendly transparent background image. Hook into
`omarchy hook install theme-set` so switching Omarchy themes re-skins the IME.
*Effort: days. Reliability: bulletproof.*

**B. kimpanel protocol + Quickshell plugin (native Omarchy candidate window)** —
kimpanel is a DBus UI protocol: a panel owns bus name
`org.kde.kimpanel.inputmethod`; fcitx5's kimpanel addon detects it at runtime
and hands over all rendering (preedit, auxiliary text, candidate list, spot
location) via DBus signals; actions go back via DBus. GNOME has an extension
doing exactly this; **nobody has built one for Hyprland/Quickshell. That's our
moat.** We render candidates as a layer-shell surface inside `omarchy-shell`
(same process as bar/OSD → shares the theme singleton, animations, blur).
Kill-switch safety: if our panel dies or is disabled, fcitx5 falls back to
classicui automatically (addon only activates when the name is owned).
*Effort: weeks. Payoff: the most beautiful IME on any Linux desktop.*

Protocol references collected:
- fcitx5 kimpanel addon (source: fcitx/fcitx5 repo, `libkimpanel.so`)
- wengxt/gnome-shell-extension-kimpanel — compact JS reference implementation
- KDE userbase Tutorials/Kimpanel; fcitx-im.org/wiki/Kimpanel
- Live introspection possible locally via `busctl --user`

Key engineering details to nail in B:
- Positioning: `UpdateSpotLocation` gives cursor coords (fcitx5 gets the cursor
  rect via input-method-v2 on Wayland). Place a borderless `PanelWindow`
  (layer `overlay`, `keyboardInteractivity: None`, exclusiveZone `-1`) near it;
  handle multi-monitor by matching output.
- Latency: DBus hop ≈ 1–2 ms; preedit redraw must feel instant.
- Focus: window must never take keyboard focus; clicks on candidates need
  careful handling (mouse grab vs focus stealing).

**C. Standalone Quickshell instance for the IME** — same as B but outside
`omarchy-shell`. More isolation from shell updates, but a second Quickshell
process and no shared theme singleton. Fallback if B hits shell-integration walls.

**D. Bar indicator widget (中/EN)** — independent of A/B/C. A `bar-widget`
plugin polling/subscribing to fcitx5 DBus (`CurrentInputMethod`,
StateChanged signals), click = toggle, shows 中/EN/A icon. Cheap, huge
perceived-value win. Do it early.

### 3.3 Prior art & ecosystem

- wey-gu's "Omarchy Chinese Simplified Input Config" gist — manual fcitx5+rime
  setup; proves demand, we automate + exceed it.
- hyprinputswitcher (Go daemon, Hyprland socket → fcitx5-remote) — per-app
  auto-switching idea; fcitx5's `ShareInputState=PerProgram` covers most of it
  natively, but app-class rules (e.g., force EN in certain apps) are a nice extra.
- ArchWiki Fcitx5 page — canonical troubleshooting (XWayland/Electron caveats).
- fcitx5-chinese-addons (built-in pinyin with cloudpinyin) — alternative engine;
  kept off the critical path but noted: its cloudpinyin could inspire a later
  rime-lua cloud feature.

### 3.4 Known risks

| Risk | Mitigation |
|---|---|
| XWayland/Electron apps misbehave (focus/popup position) | Test matrix in Phase 1: alacritty, foot, kitty, Chrome, Electron apps, GTK3/4, Qt6, Steam/Wine spot-checks; document flags (`--enable-wayland-ime`) where needed |
| kimpanel positioning accuracy on Hyprland | Prototype spike before committing to B; classicui theme (A) remains the shipping fallback |
| quickshell DBus API gaps (git 0.3.0) | Spike early; worst case use tiny helper script via `Quickshell.process` or C plugin |
| Schema updates break user patches | Our patches live in `*.custom.yaml` overlay files only; never fork upstream schema files |
| Two engines confusion (rime vs chinese-addons) | Ship exactly one path; uninstall guide for the other |

## 4. Architecture (target)

```
┌────────────────────────── omarchy-shell (Quickshell) ──────────────────────────┐
│  ┌───────────────┐   ┌──────────────────────────┐   ┌────────────────────────┐ │
│  │ bar-widget    │   │ omarime.candidate        │   │ theme singleton        │ │
│  │ 中/EN + click │   │ kimpanel panel (layer-   │   │ (colors, radius, font) │ │
│  │ = toggle      │   │ shell overlay, animated) │◄──┤                        │ │
│  └──────┬────────┘   └───────────┬──────────────┘   └────────────────────────┘ │
└─────────┼────────────────────────┼──────────────────────────────────────────────┘
          │ DBus org.fcitx.Fcitx.Controller1        │ DBus org.kde.kimpanel.inputmethod
┌─────────▼────────────────────────▼─────────────┐
│ fcitx5 (omarchy-fcitx5.service)                │
│   └─ fcitx5-rime → rime-ice / wanxiang schema  │
│      + our *.custom.yaml patch layer           │
└────────────────────────────────────────────────┘
          ▲
   Hyprland bindings: Super+Space → fcitx5-remote -t (+ Ctrl+Space in-engine)
```

Repo layout:

```
omarime/
├── PLAN.md                  # this file
├── README.md                # user-facing intro & quickstart
├── docs/
│   ├── research.md          # links & notes from investigation
│   └── architecture.md      # deep-dive on chosen option (Phase 2 exit)
├── engine/
│   ├── install.sh           # AUR deps + schema deploy + deploy + verify
│   ├── rime-ice.patch/      # default.custom.yaml etc. (our overlay layer)
│   └── wanxiang.patch/
├── hypr/
│   └── bindings.snippet.lua # Super+Space toggle binding + comments
├── plugins/
│   ├── omarime.indicator/   # Phase 2: bar-widget (manifest.json + QML)
│   └── omarime.candidate/   # Phase 3: kimpanel panel plugin
├── themes/
│   ├── build-from-omarchy.sh# generate classicui theme from active theme
│   └── hooks/theme-set.sh   # re-skin on `omarchy theme set`
└── install.sh               # one-command setup (idempotent, backup-first)
```

## 5. Roadmap

### Phase 0 — Baseline & safety (half day)
- [ ] Backup current `~/.config/fcitx5`, `~/.local/share/fcitx5/rime`
- [ ] Record baseline UX notes (screenshots of stock luna_pinyin)
- [ ] Decide open questions (§7)

### Phase 1 — Engine excellence (1–2 days) ← biggest quality win
- [ ] `engine/install.sh`: install rime-ice (AUR or vendored), apply our patch
      layer, redeploy, set rime as default IM
- [ ] Patch layer: fuzzy-pinyin presets, Shift/Caps policy, per-program memory
      (`ShareInputState=PerProgram`), candidate count, 简繁 switch key
- [ ] Hotkeys: keep fcitx5 Ctrl+Space; add Hyprland `Super+Space` →
      `fcitx5-remote -t`; document both
- [ ] App test matrix pass; write `docs/troubleshooting.md`
- [ ] Acceptance: typing feels ≥ Sogou-on-Windows for daily sentences; toggle
      works everywhere; no focus bugs in the matrix

### Phase 2 — Beauty pass + indicator (2–3 days)
- [ ] `themes/build-from-omarchy.sh`: classicui theme generated from active
      Omarchy palette (dark/light aware), Sarasa/Noto CJK font check/install
- [ ] `theme-set` hook so IME follows `omarchy theme set`
- [ ] `plugins/omarime.indicator`: bar widget 中/EN, click-to-toggle, tooltip
      with current schema; publish to your plugins repo
- [ ] Optional: OSD toast on mode switch if omarchy.osd exposes generic text IPC
- [ ] Acceptance: screenshots that look at home next to Omarchy defaults

### Phase 3 — The moonshot: native candidate window (1–2 weeks)
- [ ] Spike: minimal Quickshell DBus listener owning `org.kde.kimpanel.inputmethod`;
      confirm fcitx5 switches `CurrentUI` to kimpanel; dump signal traffic
- [ ] Render preedit + candidates near spot location; number/click/page actions
- [ ] Polish: theme singleton colors, radius/blur/shadow, show/hide animation,
      multi-monitor, DPI scaling, vertical/horizontal layouts
- [ ] Safety: disable-switch (falls back to classicui), crash-safe fallback
- [ ] Acceptance: side-by-side video vs classicui; zero perceptible latency

### Phase 4 — Package & share
- [ ] Single `install.sh` / `uninstall.sh`, idempotent, backup-first
- [ ] README with screenshots/GIFs (中英双语)
- [ ] Publish repo; consider PR to omarchy-community / gist upgrade thread

## 6. Why this will be good (design principles)

1. **Thin overlay, thick upstream.** We never fork rime-ice/wanxiang/fcitx5;
   every customization is an overlay (`*.custom.yaml`, themes, plugins) so
   upstream updates keep flowing.
2. **Degrade gracefully.** Every fancy layer has a boring fallback: custom UI →
   themed classicui → stock. Nothing bricks typing.
3. **Native or nothing.** If it doesn't look like Omarchy shipped it, it's not done.
4. **Measure the feel.** Latency budget for candidate render < 16 ms/frame;
   toggle feedback instant (indicator + optional toast).

## 7. Open decisions (need your call)

1. **Default schema:** rime-ice (recommended) or wanxiang? Or installer flag with ice default?
2. **Toggle hotkey:** Super+Space? (Ctrl+Space stays as in-engine fallback either way)
3. **双拼:** ship Xiaohe/Ziranma profiles now or later?
4. **Phase order:** agree with 1→2→3, or jump straight to the kimpanel prototype after Phase 1?
5. **License:** MIT like your other repos?

## 8. References

- https://github.com/iDvel/rime-ice — 雾凇拼音
- https://github.com/amzxyz/rime-wanxiang — 万象拼音
- https://fcitx-im.org/wiki/Kimpanel — kimpanel overview
- https://github.com/wengxt/gnome-shell-extension-kimpanel — reference panel impl
- https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland — Wayland app notes
- https://wiki.archlinux.org/title/Fcitx5 — ArchWiki
- https://gist.github.com/wey-gu/2875e6037829fa3e78b5f2e5365b71c2 — prior Omarchy manual setup
- https://fcitx-im.org/wiki/Theme_Customization — classicui theme engine
- Local: `busctl --user introspect org.fcitx.Fcitx5 /controller` — live API
