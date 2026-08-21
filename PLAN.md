# omarime — A product-grade Chinese IME for Omarchy

> Omarchy + RIME→libime + IME. 目标：Gboard 级别的"越用越好用"，Omarchy 级别的颜值。

Status: **v2 plan (engine pivot)** · Target: Omarchy 4.x · Date: 2026-02
Supersedes: rime-ice-based plan (v1) — rejected after real-world evaluation.

---

## 0. Why we pivoted (the honest engineering reason)

v1 assumed "deploy rime-ice = done". Real usage disproved it. The user's
complaint decomposes into three architectural facts about RIME:

| Complaint | Root cause in RIME's architecture |
|---|---|
| "输入预测很差" | RIME decodes **word-by-word with static, hand-tuned weights**. No sentence-level language model by default (grammar model is an optional plugin most schemas don't ship). It can't know "银行" is likelier after "去" than "很". |
| "输入和词库的映射太差" | Syllable→candidate mapping is dict-order driven; when multiple words share pinyin, ranking is fixed priorities, not context probability. |
| "用户词频习惯处理不好" | User dict boosts single words in a userdb. No context adaptation, no decay model, no sentence-level relearning. |

**What Gboard/谷歌拼音 actually does** (the thing the user misses):
1. **Sentence-level decoding**: pinyin syllable lattice → Viterbi/beam search
   over a **language model** (n-gram historically; neural in modern builds).
2. **Online user adaptation**: a small **user language model** interpolated with
   the base LM, updated as you type, with frequency decay. This is the
   "越用越好用".
3. Prediction (next-word), correction (typo-tolerant pinyin), 中英混输.

## 1. The decisive discovery

**libime** (by fcitx5's author, wengxt) is a production C++ IME engine library
that already implements exactly this architecture — it powers fcitx5's
built-in Pinyin (fcitx5-chinese-addons). Verified from the Arch package file
list (libime 1.1.15):

```
core/decoder.h  core/lattice.h          # beam/Viterbi decoder over a lattice
core/languagemodel.h                    # LM interface (trie SLM format)
core/userlanguagemodel.h                # ← online user LM adaptation
core/historybigram.h                    # ← user history bigram cache
core/prediction.h                       # ← next-word prediction
pinyin/pinyincontext.h                  # full pinyin session API
pinyin/pinyincorrectionprofile.h        # ← typo/fuzzy correction profiles
tools: libime_pinyindict (build dicts), libime_slm_build_binary (build LM),
       libime_prediction, libime_history
```

**The catch — and our product opportunity:** the shipped `zh_CN.lm` trigram
model descends from the sunpinyin-era `lm_sc.3gm` corpus (~2008–2010 web/People's
Daily data). The *decoder* is good; the *model* is ancient. That — not the
architecture — is why stock fcitx5-pinyin also disappoints on modern
vocabulary and prediction, and why everyone flees to rime-ice's dictionaries
(which don't fix the model problem either).

**omarime = keep the proven decoder, train the missing modern brain, wrap it in
a beautiful native UI.**

## 2. Module selection (best-of-breed assembly)

| Layer | Choice | Why | Alternative rejected |
|---|---|---|---|
| Frontend/protocol | **fcitx5** (already in Omarchy) | text-input-v3 + input-method-v2, DBus API verified live | ibus (GNOME-centric), raw zwp (rebuild the world) |
| Engine core | **libime** via fcitx5-pinyin (v1) → own thin fcitx5 addon linking libime (v2, for full control) | proven decoder + user LM + prediction + correction, C++, fast | RIME (static weights, weak adaptation — the reason for this pivot) |
| Language model | **Ours**: trigram trained with **kenlm** on modern corpora → ARPA → `libime_slm_build_binary` | the single highest-leverage quality lever; nobody ships a fresh one | octagram grammar for rime (still inside rime's weak adaptation loop) |
| Dictionaries | **Ours**: curated merge (zhwiki titles, THUOCL, open Sogou-cell conversions, Jun Da freq) → `libime_pinyindict` | dict quality = coverage; LM quality = ranking | rime-ice dicts (good data, wrong engine) |
| User adaptation | libime **UserLanguageModel + HistoryBigram**, tuned & verified on | the "越用越好用" property, built-in | rime userdb (single-word boost only) |
| Cloud (opt-in) | fcitx5 cloudpinyin addon, **off by default** | privacy-first; optional boost | — |
| Candidate UI | **kimpanel → Quickshell plugin** in omarchy-shell | native Omarchy look; nobody has built this for Hyprland (verified) | classicui themes (fallback only) |
| Indicator/toggle | bar-widget + `Super+Space` → `fcitx5-remote -t` + per-program memory (`ShareInputState=PerProgram`) | trivial, high value | — |
| Packaging | install.sh (idempotent, backup-first) + AUR where possible | out-of-box | — |

**v2 research track (post-1.0):** neural rescoring — small transformer LM
(6-layer class, int8, CPU-realtime) shallow-fused into the beam; either patch
libime's scoring hook or fork decoder into `omarime-engine` (Rust).
Paper-informed targets (see docs/research/gboard-research.md): Google IME
scores P@1=70.9 on the PD benchmark; PinyinGPT (beam=16) reaches 73.15 with a
pinyin-constrained vocabulary — the key trick for abbreviated-pinyin input.
Also evaluate mozc's recent neural work as architectural reference.
Gboard black-box research program: docs/research/gboard-research.md.

## 3. Architecture

```
┌────────────────────────── omarchy-shell (Quickshell) ─────────────────────┐
│  [bar-widget 中/EN]   [kimpanel candidate overlay]   [theme singleton]    │
└───────┬──────────────────────┬────────────────────────────────────────────┘
        │ Controller1 DBus     │ org.kde.kimpanel.inputmethod
┌───────▼──────────────────────▼───────────────────────────────────────────┐
│ fcitx5 (omarchy-fcitx5.service)                                          │
│  └─ pinyin addon (fcitx5-chinese-addons / later: omarime addon)          │
│      ├─ libime decoder + PinyinCorrection + Prediction                   │
│      ├─ omarime.lm  ← OUR modern trigram (kenlm → libime SLM binary)     │
│      ├─ omarime.dict ← OUR merged dictionaries (libime_pinyindict)       │
│      └─ UserLanguageModel (~/.local/share/fcitx5/pinyin/)  越用越好用      │
└──────────────────────────────────────────────────────────────────────────┘
```

Repo layout:

```
omarime/
├── PLAN.md, README.md
├── docs/                     # research, architecture, eval methodology
│   └── research/gboard-research.md  # Gboard black-box program + benchmarks
├── data/
│   ├── corpora/README.md     # sources, licenses, prep scripts
│   ├── dicts/                # curated dict sources + merge rules
│   └── eval/                 # test sentences (pinyin → expected hanzi)
├── lm/
│   ├── train.sh              # clean → segment → kenlm → ARPA → libime binary
│   └── eval.sh               # CER/top-1 on eval set, old-LM vs omarime-LM
├── engine/                   # fcitx5 config layer, fuzzy presets, hotkeys
├── hypr/                     # bindings snippet
├── plugins/
│   ├── omarime.indicator/    # bar-widget 中/EN (Phase 3)
│   └── omarime.candidate/    # kimpanel Quickshell overlay (Phase 4)
├── themes/                   # classicui theme generator + theme-set hook
├── research/apk/             # Gboard APK staging (gitignored, never commit)
└── install.sh
```

## 4. The data/LM pipeline (the actual "REALLY GOOD" work)

Corpus landscape audited (details in docs/research/lm-training-feasibility.md):
CLUECorpus2020 100GB, WuDao 200GB, THUCNews 740k news, SogouCA, zhwiki,
OPUS OpenSubtitles (colloquial — weighted up), ChineseWebText 2.0.
Key technical constraint: LM tokenization must align with dictionary vocabulary.
- zhwiki + wiktionary titles (CC BY-SA) — entity coverage
- THUCNews / People's Daily 1998 (research licenses) — clean formal text
- OpenSubtitles zh — colloquial sentence flow (what Gboard-style IMEs weight heavily)
- zhwiki word freq (fcitx5-pinyin-zhwiki tooling exists as reference)
- Community open dicts: jiejie/THUOCL cells for dict merge only

Pipeline: clean → jieba/lac segment → dedupe → kenlm trigram (prune) →
ARPA → `libime_slm_build_binary` → swap-in test. Target size: 20–80 MB binary
(in-memory trie, load < 200 ms).

**Eval harness (non-negotiable):** a growing test set of real sentences with
pinyin keys (news/colloquial/names/internet slang buckets); metric = top-1
sentence accuracy + top-10 hit rate; every LM/dict iteration must beat the
previous on the harness *and* in a blind feel-test. This is how we avoid
"rime-ice felt bad" subjectivity drift.

## 5. Roadmap

### Phase 0 — Baseline & safety (half day)
- [ ] Backup fcitx5/rime state; screenshots of current feel
- [ ] Install fcitx5-chinese-addons + libime; enable pinyin IM; keep rime as fallback
- [ ] Confirm user-model files appear under `~/.local/share/fcitx5/pinyin/`

### Phase 1 — Engine baseline that doesn't embarrass us (1–2 days)
- [ ] fcitx5-pinyin configured: fuzzy presets, 双拼 profile, prediction ON,
      correction ON, `ShareInputState=PerProgram`, cloud OFF
- [ ] Hotkeys: `Super+Space` (Hyprland → `fcitx5-remote -t`) + Ctrl+Space
- [ ] App test matrix (alacritty/foot/kitty/Chrome/Electron/GTK/Qt/XWayland)
- [ ] Exit: daily typing works everywhere, toggle instant, per-app memory holds

### Phase 2 — The brain: data + LM + eval (1–2 weeks, the core R&D)
- [ ] Corpus collection + license audit + prep scripts
- [ ] kenlm trigram v1; convert; A/B vs stock zh_CN.lm on eval harness
- [ ] Dict merge v1 → `libime_pinyindict`; coverage check for names/slang
- [ ] User-model tuning: verify adaptation actually updates candidates
      (type a name 3×, it should rank #1); document reset/sync
- [ ] Exit: eval harness shows ≥ stock by a wide margin; blind test preferred

### Phase 3 — Beauty + indicator (2–3 days)
- [ ] classicui theme generated from active Omarchy theme + `theme-set` hook
- [ ] `omarime.indicator` bar widget (中/EN, click-toggle, schema tooltip)
- [ ] Optional OSD toast on switch

### Phase 4 — Native candidate window (1–2 weeks)
- [ ] kimpanel spike: Quickshell DBus listener owns `org.kde.kimpanel.inputmethod`;
      fcitx5 `CurrentUI` switches; dump signal traffic
- [ ] Full overlay: spot-location placement, multi-monitor, DPI, animations,
      blur, vertical/horizontal layouts, click/page actions
- [ ] Kill-switch: disable plugin → classicui fallback (verified behavior)

### Phase 5 — Product & publish
- [ ] `install.sh`/`uninstall.sh`, README (中英双语, GIFs), eval results published
- [ ] Consider upstreaming LM findings to fcitx5-chinese-addons community

### Phase 6 — v2 research track (optional, post-1.0)
- [ ] Eval harness upgrade: add PD-benchmark bucket (published baseline to
      beat: Google IME P@1=70.9) + modern-corpus + slang buckets
- [ ] Neural rescoring spike (pinyin-constrained vocab trick for 缩写输入);
      mozc architecture study; own-decoder feasibility
- [ ] Fold in Gboard teardown findings (docs/research/gboard-research.md)

## 6. Risks

| Risk | Mitigation |
|---|---|
| kenlm trigram still < Gboard quality | Gboard's edge is data volume + neural; we close the gap iteratively (Phase 6). Stock LM autopsy: only 2.2M trigrams (188MB ARPA) — a 20-100x modern corpus is a likely win, not a bet. See docs/research/lm-training-feasibility.md |
| ~~libime LM format~~ **RESOLVED**: libime embeds kenlm; official pipeline = ARPA → `slm_build_binary -q 4 trie`. Our training path is identical to upstream's. |
| User-model behavior unclear/buggy | Phase 0/2 verification tasks; worst case implement our own adaptation layer via own addon (v2) |
| Corpora licenses | Audit before shipping; prefer CC BY-SA / research-permitted; never ship scraped-proprietary text |
| kimpanel positioning on Hyprland | Spike first (Phase 4), classicui theme remains shipping fallback |
| XWayland/Electron quirks | Known flags documented in troubleshooting.md; test matrix gate |

## 7. Open decisions

1. ~~rime-ice vs wanxiang~~ → moot (engine pivoted to libime)
2. 双拼 in Phase 1 or later? (config-only, cheap — default: include Xiaohe)
3. Cloud pinyin: keep OFF by default? (recommend OFF)
4. Phase order OK? (1 → 2 → 3 → 4; Phase 2 is the long pole)
5. License for omarime itself: MIT? (data files keep their own licenses)

## 8. References

**Engine/libime**
- https://github.com/fcitx/libime — decoder, UserLanguageModel, Prediction
- https://github.com/fcitx/fcitx5-chinese-addons — reference frontend
- Local: `pacman -Fl libime` — tools verified: `libime_pinyindict`,
  `libime_slm_build_binary`, `libime_prediction`, `libime_history`
- https://github.com/fcitx/fcitx5 — frontend/DBus (verified live introspection)

**LM training**
- docs/research/lm-training-feasibility.md — full feasibility study (stock LM autopsy,
  corpus landscape, pipeline, compute budget)
- https://github.com/kpu/kenlm — trigram training
- 墨奇科技 blog: "每个人都可以训练自己的语言模型" (corpus→segment→train recipe)
- https://zhuanlan.zhihu.com/p/710756084 — rime grammar LM training (concept parity)

**Papers (quality targets)**
- arXiv:2203.00249 — Exploring and Adapting Chinese GPT to Pinyin Input Method
  (Google IME baseline P@1=70.9 on PD; PinyinGPT 73.15; beam=16;
  pinyin-constrained vocab for abbreviated pinyin; CC BY 4.0)
- Microsoft Research — A New Statistical Approach to Chinese Pinyin Input
  (the classic trigram-decoder architecture libime descends from)
- ACL Y15-1052 — Neural Network Language Model for Chinese Pinyin IME
- Yang et al. 2012 — PD dataset (People's Daily 92–98, 5.04M train / 2k test)
  → reusable as our news-domain eval bucket

**Prior art / context**
- https://github.com/iDvel/rime-ice — great dicts, weak engine fit (our v1 lesson)
- https://github.com/amzxyz/rime-wanxiang — octagram grammar in rime
- https://github.com/gaboolic/rime-frost — corpus-prep scripting reference
- sunpinyin — historical SLM engine (origin of lm_sc.3gm shipped today)
- Google Pinyin/Gboard — product north star (sentence decode + adaptation)

**UI** (unchanged from v1)
- kimpanel: https://fcitx-im.org/wiki/Kimpanel + wengxt/gnome-shell-extension-kimpanel
- https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland · ArchWiki Fcitx5
- Omarchy plugin kinds & IPC verified locally (see docs/research.md)
