#!/usr/bin/env bash
# Macro IME installer — Omarchy-native Chinese IME experience.
#
#   ./install.sh [options]          install everything and apply now
#   ./install.sh --undo             full rollback
#
# Options:
#   --lm-file <path>   path to zh_CN.lm (E6 language model, ~463MB).
#                      If not provided, downloads from the newest release
#                      that carries the model (not per-version re-uploads:
#                      unchanged models stay on their original release).
#   --skip-lm          skip LM install (UI only, no engine model).
#   --offline          do not download; fail if the LM is missing locally.
#
# All files go under user directories — no root, no /usr modification.
# The LM is loaded via the LIBIME_MODEL_DIRS env var (systemd drop-in),
# never by overwriting a system file.
#
# Transaction model:
#   Everything that does not touch fcitx5 while it runs (downloads, addon
#   files, runtime files, plugins) happens first. fcitx5 is stopped only for
#   a short commit phase (config edit + LM copy), restarted, then verified
#   (service active, addon loaded, state file written). If anything fails,
#   on_error restarts fcitx5 so the machine is never left without an IME.
#
# Installed-model tracking: ~/.local/share/macro-ime/lib/model-manifest.json
# records the release + sha256 of the installed LM. Reinstalls skip only when
# the manifest matches the pinned release *and* the files verify; a VERSION
# bump therefore really updates the model.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACRO_IME_HOME="${HOME}/.local/share/macro-ime"
MACRO_IME_LIB="${MACRO_IME_HOME}/lib"
MACRO_IME_LM_DIR="${MACRO_IME_LIB}"
PLUGIN_DIR="${HOME}/.config/omarchy/plugins"
UI_CONF="${HOME}/.config/fcitx5/conf/classicui.conf"
CORE_CONF="${HOME}/.config/fcitx5/config"
PY_CONF="${HOME}/.config/fcitx5/conf/pinyin.conf"
BACKUP_DIR="$MACRO_IME_HOME/backup"
STATE_ADDON_CONF="${HOME}/.local/share/fcitx5/addon/macro-ime-state.conf"
FCITX_DROPIN="${HOME}/.config/systemd/user/omarchy-fcitx5.service.d/macro-ime-state.conf"
RUNTIME_STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/macro-ime"
MANIFEST="${MACRO_IME_LM_DIR}/model-manifest.json"
GH_REPO="forbidden-game/macro-ime"

LM_FILENAME="zh_CN.lm"
LM_PREDICT_FILENAME="zh_CN.lm.predict"

# Pinned engine-assets release (keeps UI-from-git and .so/.lm in sync).
# Resolved in load_version() (called from main) so the definition section of
# this script stays side-effect-free.
VERSION=""
RELEASE_TAG=""

# --- parse options -----------------------------------------------------------
LM_FILE=""
SKIP_LM=0
OFFLINE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --lm-file)  LM_FILE="${2:?--lm-file requires a path}"; shift 2 ;;
    --skip-lm)  SKIP_LM=1; shift ;;
    --offline)  OFFLINE=1; shift ;;
    --undo)     break ;;   # handled in main
    -h|--help)  awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/,""); print } else if (NF) exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# --- progress + error handling -----------------------------------------------
if [[ -t 2 ]]; then C_B=$'\033[1;36m' C_R=$'\033[0;31m' C_G=$'\033[0;32m' C_0=$'\033[0m'
else               C_B=''; C_R=''; C_G=''; C_0=''; fi

step() { printf '\n%s==> [%s/%s] %s%s\n' "$C_B" "$1" "$2" "$3" "$C_0"; }
note() { printf '    %s\n' "$1"; }
ok()   { printf '%s    \u2713 %s%s\n' "$C_G" "$1" "$C_0"; }

# State of fcitx5 across the commit phase: 1 = we stopped it and owe a start.
FCITX_NEED_RESTART=0
# Re-entry guard for on_error (bash fires ERR twice for failures in $(...)).
ERROR_HANDLED=0

# --- functions (all defined before use) --------------------------------------

require_commands() {
  local missing=() c
  for c in omarchy omarchy-shell systemctl fcitx5 fcitx5-remote jq busctl hyprctl fc-match; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  # fcitx5-chinese-addons ships the pinyin engine that Macro IME builds on.
  # Without it the LM would never be used.
  [[ -f /usr/share/fcitx5/addon/pinyin.conf ]] || \
    missing+=("fcitx5-chinese-addons (pinyin addon) — install with: omarchy pkg add fcitx5-chinese-addons")
  # Build tools only when we actually have to compile the addon from source.
  if [[ ! -f "${SRC}/dist/libmacro-ime-state.so" ]]; then
    for c in pkg-config cmake c++; do
      command -v "$c" >/dev/null || \
        missing+=("$c (to build the addon; or provide dist/libmacro-ime-state.so)")
    done
    pkg-config --exists 'Fcitx5Core >= 5.1' 2>/dev/null || \
      missing+=("Fcitx5Core >= 5.1 (fcitx5 dev headers — to build the addon)")
  fi
  if (( ${#missing[@]} )); then
    printf '%s✗ macro-ime: missing required dependencies:%s\n' "$C_R" "$C_0" >&2
    for m in "${missing[@]}"; do printf '    - %s\n' "$m" >&2; done
    printf '  Install them, then re-run: %s\n' "$0" >&2
    exit 1
  fi
}

on_error() {
  local code=$? line=$1
  trap - ERR
  # bash's set -E makes the ERR trap fire TWICE for a failure inside $(...):
  # once in the command-substitution subshell, once in the parent. The
  # subshell must stay silent — the parent runs the real handler.
  if (( BASH_SUBSHELL > 0 )); then
    exit "$code"
  fi
  if (( ERROR_HANDLED )); then
    exit "$code"
  fi
  ERROR_HANDLED=1
  printf '\n%s✗ macro-ime: install failed (exit %s, near line %s).%s\n' \
    "$C_R" "$code" "$line" "$C_0" >&2
  # Never leave the machine without an input method: if we stopped fcitx5
  # during the commit phase and it is not running, bring it back.
  if (( FCITX_NEED_RESTART )) && ! service_running; then
    systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
    if systemctl --user start omarchy-fcitx5.service 2>/dev/null; then
      FCITX_NEED_RESTART=0
      printf '  fcitx5 was stopped mid-install; it has been started again.%s\n' "$C_0" >&2
    else
      printf '  fcitx5 was stopped mid-install and could NOT be restarted —%s\n' "$C_0" >&2
      printf '    run: systemctl --user start omarchy-fcitx5.service%s\n' "$C_0" >&2
    fi
  fi
  printf '  A partial install may remain on this machine. Roll everything back with:\n' >&2
  printf '      %s --undo\n' "$0" >&2
  [[ -n "$LM_DL_DIR" ]] && rm -rf "$LM_DL_DIR"
  exit "$code"
}

service_running() {
  case $(systemctl --user is-active omarchy-fcitx5.service 2>/dev/null || true) in
    active|activating|reloading) return 0 ;;
  esac
  pgrep -x fcitx5 >/dev/null 2>&1
}

stop_fcitx() {
  # Stop fcitx5 and remember that we owe a restart (sets FCITX_NEED_RESTART).
  if service_running; then
    systemctl --user stop omarchy-fcitx5.service 2>/dev/null || true
    pkill -x fcitx5 2>/dev/null || true
    FCITX_NEED_RESTART=1
  fi
  # The 463MB LM is memory-mapped; give the process time to unmap + exit.
  for _ in {1..150}; do pgrep -x fcitx5 >/dev/null || return 0; sleep 0.1; done
  echo "macro-ime: fcitx5 did not stop within 15s" >&2
  return 1
}

restart_fcitx() {
  if (( FCITX_NEED_RESTART )); then
    systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
    systemctl --user start omarchy-fcitx5.service
    FCITX_NEED_RESTART=0
  fi
}

restore_file() {
  local backup=$1 destination=$2
  if [[ -f "$BACKUP_DIR/$backup" ]]; then
    mkdir -p "$(dirname "$destination")"
    cp "$BACKUP_DIR/$backup" "$destination"
  elif [[ -f "$BACKUP_DIR/$backup.missing" ]]; then
    rm -f "$destination"
  fi
}

backup_file_once() {
  local source=$1 backup=$2
  mkdir -p "$BACKUP_DIR"
  [[ -e "$BACKUP_DIR/$backup" || -e "$BACKUP_DIR/$backup.missing" ]] && return
  if [[ -f $source ]]; then cp "$source" "$BACKUP_DIR/$backup"
  else touch "$BACKUP_DIR/$backup.missing"
  fi
}

restore_plugin_dir() {
  local p=$1
  local dst="${PLUGIN_DIR:?}/$p"
  if [[ -e "$BACKUP_DIR/plugin-$p" ]]; then
    rm -rf "$dst"
    cp -r "$BACKUP_DIR/plugin-$p" "$dst"
  else
    rm -rf "$dst"
  fi
}

undo() {
  step 1 3 "Stopping fcitx5"
  if ! stop_fcitx; then
    printf '%s✗ fcitx5 is still running; aborting undo to protect live files.%s\n' "$C_R" "$C_0" >&2
    printf '  Quit the IM (or wait for fcitx5 to exit), then re-run: %s --undo\n' "$0" >&2
    return 1
  fi
  ok "fcitx5 stopped"
  step 2 3 "Restoring original fcitx5 config"
  restore_file classicui.conf "$UI_CONF"
  restore_file config "$CORE_CONF"
  restore_file pinyin.conf "$PY_CONF"
  restore_file state-addon.conf "$STATE_ADDON_CONF"
  restore_file fcitx-dropin.conf "$FCITX_DROPIN"
  ok "config restored"
  step 3 3 "Removing installed files + restoring pre-install plugin state"
  omarchy plugin disable macro-ime.indicator >/dev/null 2>&1 || true
  omarchy plugin disable macro-ime.settings >/dev/null 2>&1 || true
  omarchy plugin disable omarime.indicator >/dev/null 2>&1 || true
  omarchy plugin disable omarime.settings >/dev/null 2>&1 || true
  restore_plugin_dir macro-ime.indicator
  restore_plugin_dir macro-ime.settings
  # Restore enable state recorded before install (placement is not recorded
  # by omarchy; we remount on the center, as install does).
  if [[ -f "$BACKUP_DIR/plugin-state.json" ]]; then
    if [[ $(jq -r '.[] | select(.id == "macro-ime.indicator") | .enabled // false' \
          "$BACKUP_DIR/plugin-state.json" 2>/dev/null) == true ]]; then
      omarchy plugin enable macro-ime.indicator center >/dev/null 2>&1 || true
    fi
    if [[ $(jq -r '.[] | select(.id == "macro-ime.settings") | .enabled // false' \
          "$BACKUP_DIR/plugin-state.json" 2>/dev/null) == true ]]; then
      omarchy plugin enable macro-ime.settings >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$MACRO_IME_HOME" \
         "$HOME/.local/share/omarime" \
         "$HOME/.local/share/fcitx5/themes/macro-ime" \
         "$HOME/.local/share/fcitx5/themes/omarime" \
         "$HOME/.config/omarchy/hooks/theme-set.d/macro-ime.sh" \
         "$HOME/.config/omarchy/hooks/theme-set.d/omarime.sh" \
         "$RUNTIME_STATE_DIR" \
         "${XDG_RUNTIME_DIR:-/run/user/${UID}}/omarime"
  systemctl --user daemon-reload
  restart_fcitx
  ok "removed; fcitx5 config restored to its pre-install state"
}

load_version() {
  VERSION="$(cat "${SRC}/VERSION" 2>/dev/null || true)"
  if [[ -z "$VERSION" ]]; then
    echo "macro-ime: no VERSION file in ${SRC}; cannot pin engine assets." >&2
    echo "  Create ${SRC}/VERSION with the release version (e.g. 0.1.0)." >&2
    exit 1
  fi
  RELEASE_TAG="v${VERSION}"
}

# sha256 of a release asset, from GitHub's recorded digest. Empty on failure.
gh_release_digest() {
  local name=$1 release=$2
  gh api "repos/${GH_REPO}/releases/tags/${release}" \
    --jq ".assets[] | select(.name == \"${name}\") | .digest // \"\" | sub(\"^sha256:\"; \"\")" \
    2>/dev/null || true
}

# The newest release that actually carries the LM assets. The LM bytes
# rarely change, and unchanged models are never re-uploaded per release —
# installs resolve the owning release implicitly. A model update therefore
# means: upload the new zh_CN.lm to the new release, and installs pick it
# up automatically (digest differs from the manifest).
resolve_lm_release() {
  gh api "repos/${GH_REPO}/releases" --paginate \
    --jq '.[] | select(any(.assets[]?; .name == "zh_CN.lm")) | .tag_name' \
    2>/dev/null | head -1
}

# Strict sha256 check — fail-closed: an unavailable digest is an error, not a
# pass. Used for downloads from the pinned release.
assert_sha256() {
  local file=$1 expected=$2 label=$3
  local actual
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "macro-ime: no sha256 digest available for ${label} (release ${LM_RELEASE:-unknown} API?)" >&2
    return 1
  fi
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  if [[ "$actual" != "$expected" ]]; then
    echo "macro-ime: sha256 mismatch for ${label}" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

# Loose sanity check for local files (--lm-file / dist): size only.
check_lm_size() {
  local file=$1 label=$2
  local size
  size=$(stat -c%s "$file")
  if [[ "$label" == "$LM_FILENAME" && "$size" -lt 100000000 ]]; then
    echo "macro-ime: ${label} is only ${size} bytes (expected ~463MB); looks truncated" >&2
    return 1
  fi
}

# --- language model ----------------------------------------------------------
# Resolution happens up-front (downloads/verification) with no effect on the
# live tree; the actual copy + manifest are committed in the commit phase.
LM_SRC=""
LM_PREDICT_SRC=""
LM_SOURCE=""          # release | lm-file | dist
LM_RELEASE=""         # newest release carrying zh_CN.lm (source of truth)
LM_DL_DIR=""          # temp download dir, kept until commit copies the files
commit_manifest_only=0  # 1 = files already match this release; just write the manifest

prepare_language_model() {
  if (( SKIP_LM )); then
    note "skipped (--skip-lm)"
    ok "language model skipped"
    return 0
  fi

  # Newest release carrying zh_CN.lm — the source of truth for "current"
  # model bytes. Never resolved in --offline mode (no network at all) or
  # when an explicit --lm-file was given (no release involvement).
  LM_RELEASE=""
  if (( ! OFFLINE )) && [[ -z "$LM_FILE" ]]; then
    LM_RELEASE="$(resolve_lm_release)"
  fi
  if [[ -z "$LM_RELEASE" ]]; then
    note "(no LM release resolution — offline or gh unavailable)"
  else
    note "LM assets resolved from release ${LM_RELEASE}"
  fi

  local lm_dest="${MACRO_IME_LM_DIR}/${LM_FILENAME}"
  local predict_dest="${MACRO_IME_LM_DIR}/${LM_PREDICT_FILENAME}"

  # --- 1. Already installed and verified against the current LM release?
  #        (--lm-file always bypasses this: an explicit file wins.)
  if [[ -z "$LM_FILE" && -f "$MANIFEST" && -f "$lm_dest" ]]; then
    local mrel msrc lmh prh
    mrel=$(jq -r '.release // ""' "$MANIFEST" 2>/dev/null || true)
    msrc=$(jq -r '.source // ""' "$MANIFEST" 2>/dev/null || true)
    lmh=$(jq -r '.files["zh_CN.lm"].sha256 // ""' "$MANIFEST" 2>/dev/null || true)
    prh=$(jq -r '.files["zh_CN.lm.predict"].sha256 // ""' "$MANIFEST" 2>/dev/null || true)
    if [[ "$msrc" == "release" && \
          "$lmh" == "$(sha256sum "$lm_dest" | cut -d' ' -f1)" && \
          -f "$predict_dest" && "$prh" == "$(sha256sum "$predict_dest" | cut -d' ' -f1)" ]]; then
      if [[ -n "$LM_RELEASE" ]]; then
        # Online: skip only when the manifest tracks the current LM release.
        if [[ "$mrel" == "$LM_RELEASE" ]]; then
          note "LM already installed and verified (release ${LM_RELEASE})"
          ok "language model in place"
          return 0
        fi
        note "newer model available (release ${LM_RELEASE}, installed ${mrel}); updating"
      elif (( OFFLINE )); then
        # Offline: can't check for updates — trust the local manifest.
        note "LM already installed and manifest-verified; offline, skipping"
        ok "language model in place"
        return 0
      fi
    fi
  fi

  # --- 2. Migration: files exist and match the current LM release's digest?
  #        Then just (re)write the manifest — no 463MB re-download.
  if [[ -z "$LM_FILE" && -f "$lm_dest" && -f "$predict_dest" && -n "$LM_RELEASE" ]]; then
    local rd rp
    rd=$(gh_release_digest "$LM_FILENAME" "$LM_RELEASE")
    rp=$(gh_release_digest "$LM_PREDICT_FILENAME" "$LM_RELEASE")
    if [[ -n "$rd" && \
          "$rd" == "$(sha256sum "$lm_dest" | cut -d' ' -f1)" && \
          "$rp" == "$(sha256sum "$predict_dest" | cut -d' ' -f1)" ]]; then
      commit_manifest_only=1
      LM_SOURCE="release"
      note "existing LM matches release ${LM_RELEASE} — just updating the manifest"
      ok "language model verified against release ${LM_RELEASE}"
      return 0
    fi
  fi

  # --- 3. Resolve a source: --lm-file / dist / pinned release download.
  if [[ -n "$LM_FILE" ]]; then
    if [[ ! -f "$LM_FILE" ]]; then
      echo "macro-ime: LM file not found: $LM_FILE" >&2
      return 1
    fi
    LM_SRC="$LM_FILE"
    LM_PREDICT_SRC="${LM_FILE}.predict"
    if [[ ! -f "$LM_PREDICT_SRC" ]]; then
      note "warning: no ${LM_PREDICT_FILENAME} next to $LM_FILE — prediction will be off"
      LM_PREDICT_SRC=""
    elif [[ $(stat -c%s "$LM_PREDICT_SRC") -lt 1000000 ]]; then
      echo "macro-ime: ${LM_PREDICT_SRC} is only $(stat -c%s "$LM_PREDICT_SRC") bytes (expected ~3.9MB); looks truncated" >&2
      return 1
    fi
    LM_SOURCE="lm-file"
    check_lm_size "$LM_SRC" "$LM_FILENAME" || return 1
    note "using LM from: $LM_SRC (not verified against the release digest)"
  elif [[ -f "${SRC}/dist/${LM_FILENAME}" ]]; then
    LM_SRC="${SRC}/dist/${LM_FILENAME}"
    LM_PREDICT_SRC="${SRC}/dist/${LM_PREDICT_FILENAME}"
    if [[ ! -f "$LM_PREDICT_SRC" ]]; then
      LM_PREDICT_SRC=""
    elif [[ $(stat -c%s "$LM_PREDICT_SRC") -lt 1000000 ]]; then
      echo "macro-ime: ${LM_PREDICT_SRC} is only $(stat -c%s "$LM_PREDICT_SRC") bytes (expected ~3.9MB); looks truncated" >&2
      return 1
    fi
    LM_SOURCE="dist"
    check_lm_size "$LM_SRC" "$LM_FILENAME" || return 1
    note "using LM from repo dist/ directory (not verified against the release digest)"
  else
    if (( OFFLINE )); then
      if [[ -f "$lm_dest" ]]; then
        echo "macro-ime: LM files exist locally but are not verified" >&2
        echo "  (missing/mismatched ${MANIFEST}, and --offline cannot resolve the release)." >&2
        echo "  Re-run online once to verify, or delete the old files to reinstall:" >&2
        echo "    rm -f ${MACRO_IME_LM_DIR}/${LM_FILENAME} ${MACRO_IME_LM_DIR}/${LM_PREDICT_FILENAME}" >&2
      else
        echo "macro-ime: LM not found locally and --offline is set." >&2
        echo "  Place it at dist/${LM_FILENAME} or use --lm-file <path>" >&2
      fi
      return 1
    fi
    if ! command -v gh >/dev/null; then
      echo "macro-ime: 'gh' CLI is required to download the language model from the" >&2
      echo "  private release. Run 'gh auth login' first, or use --lm-file <path>." >&2
      return 1
    fi
    if [[ -z "$LM_RELEASE" ]]; then
      echo "macro-ime: cannot resolve a release that carries ${LM_FILENAME}." >&2
      echo "  Upload the model to a release, or use --lm-file <path>." >&2
      return 1
    fi
    LM_DL_DIR=$(mktemp -d)
    note "downloading language model from release ${LM_RELEASE} (~463MB)…"
    gh release download "$LM_RELEASE" --repo "$GH_REPO" \
      --pattern "$LM_FILENAME" --pattern "$LM_PREDICT_FILENAME" --dir "$LM_DL_DIR" \
      2>/dev/null || {
      echo "macro-ime: download from ${LM_RELEASE} failed." >&2
      echo "  Check the release exists + your gh auth, or use --lm-file." >&2
      rm -rf "$LM_DL_DIR"; LM_DL_DIR=""; return 1
    }
    LM_SRC="${LM_DL_DIR}/${LM_FILENAME}"
    LM_PREDICT_SRC="${LM_DL_DIR}/${LM_PREDICT_FILENAME}"
    if [[ ! -f "$LM_SRC" ]]; then
      echo "macro-ime: LM file missing after download" >&2
      rm -rf "$LM_DL_DIR"; LM_DL_DIR=""; return 1
    fi
    LM_SOURCE="release"
    # Fail-closed verification against the release's recorded sha256.
    local exp_lm exp_pred
    exp_lm=$(gh_release_digest "$LM_FILENAME" "$LM_RELEASE")
    exp_pred=$(gh_release_digest "$LM_PREDICT_FILENAME" "$LM_RELEASE")
    assert_sha256 "$LM_SRC" "$exp_lm" "$LM_FILENAME" \
      || { rm -rf "$LM_DL_DIR"; LM_DL_DIR=""; return 1; }
    if [[ -f "$LM_PREDICT_SRC" ]]; then
      assert_sha256 "$LM_PREDICT_SRC" "$exp_pred" "$LM_PREDICT_FILENAME" \
        || { rm -rf "$LM_DL_DIR"; LM_DL_DIR=""; return 1; }
    else
      note "warning: ${LM_PREDICT_FILENAME} not present in the release — skipping"
      LM_PREDICT_SRC=""
    fi
  fi

  ok "language model ready (source: ${LM_SOURCE})"
}

# Commit-phase: copy the staged LM into place and write the manifest.
commit_language_model() {
  local lm_dest="${MACRO_IME_LM_DIR}/${LM_FILENAME}"
  local predict_dest="${MACRO_IME_LM_DIR}/${LM_PREDICT_FILENAME}"

  if (( commit_manifest_only )); then
    write_manifest "$lm_dest" "$predict_dest"
    return 0
  fi
  [[ -z "$LM_SRC" ]] && return 0

  mkdir -p "$MACRO_IME_LM_DIR"
  cp "$LM_SRC" "$lm_dest"
  if [[ -n "$LM_PREDICT_SRC" ]]; then
    cp "$LM_PREDICT_SRC" "$predict_dest"
  fi
  write_manifest "$lm_dest" "$predict_dest"
  note "language model installed ($(du -h "$lm_dest" | cut -f1))"
}

write_manifest() {
  local lm_dest=$1 predict_dest=$2
  local lmh lmb pr prb files_json
  lmh=$(sha256sum "$lm_dest" | cut -d' ' -f1)
  lmb=$(stat -c%s "$lm_dest")
  pr=""; prb=""
  if [[ -f "$predict_dest" ]]; then
    pr=$(sha256sum "$predict_dest" | cut -d' ' -f1)
    prb=$(stat -c%s "$predict_dest")
  fi
  files_json=$(jq -nc \
    --arg lm "$lmh" --arg lmb "$lmb" --arg pr "$pr" --arg prb "$prb" \
    '{"zh_CN.lm":{sha256:$lm, bytes:($lmb|tonumber)}} + (if $pr != "" then {"zh_CN.lm.predict":{sha256:$pr, bytes:($prb|tonumber)}} else {} end)')
  jq -n --arg release "$LM_RELEASE" --arg source "$LM_SOURCE" \
    --argjson files "$files_json" \
    '{release:$release, source:$source, files:$files}' >"${MANIFEST}.tmp"
  mv "${MANIFEST}.tmp" "$MANIFEST"
  note "model manifest updated (${MANIFEST})"
}

# --- addon -------------------------------------------------------------------
install_addon() {
  local addon_dest="${MACRO_IME_LIB}/fcitx5/libmacro-ime-state.so"
  mkdir -p "$(dirname "$addon_dest")" "$(dirname "$STATE_ADDON_CONF")" \
           "$(dirname "$FCITX_DROPIN")"

  backup_file_once "$STATE_ADDON_CONF" state-addon.conf
  backup_file_once "$FCITX_DROPIN" fcitx-dropin.conf

  # ABI preflight: the pre-built .so must resolve against this machine's
  # fcitx5. On failure fall back to compiling from source.
  local so="${SRC}/dist/libmacro-ime-state.so"
  if [[ -f "$so" ]]; then
    local bad
    bad=$(ldd -r "$so" 2>&1 | grep -E "not found|undefined symbol" || true)
    if [[ -n "$bad" ]]; then
      note "pre-built addon has unresolved ABI on this machine:"
      while IFS= read -r l; do note "  $l"; done <<<"$bad"
      if command -v cmake >/dev/null; then
        note "building from source instead (local fcitx5 ABI)"
        build_state_addon_to "$addon_dest"
        ok "event addon built from source"
      else
        echo "macro-ime: pre-built addon ABI mismatch and no build toolchain." >&2
        echo "  Install cmake + Fcitx5Core headers, or use an Omarchy release" >&2
        echo "  that matches this fcitx5." >&2
        return 1
      fi
    else
      install -m 0755 "$so" "$addon_dest"
      note "installed pre-built addon (ABI ok)"
    fi
  else
    if ! command -v cmake >/dev/null; then
      echo "macro-ime: no pre-built addon in dist/ and cmake not available." >&2
      echo "  Build it: cmake -S engine/macro-ime-state -B build && cmake --build build" >&2
      return 1
    fi
    build_state_addon_to "$addon_dest"
  fi

  # Register the addon. NOTE: fcitx5 resolves the library as name + ".so" and
  # does NOT prepend "lib", so Library= must be the exact .so name minus ".so".
  cat >"$STATE_ADDON_CONF" <<EOF
[Addon]
Name=macro-ime-state
Comment=Macro IME event bridge (writes IM state to runtime dir)
Type=SharedLibrary
Library=libmacro-ime-state
Category=Module
Version=${VERSION}
OnDemand=False
EOF

  # Drop-in: point libime at our LM dir and fcitx5 at our addon lib dir.
  # /usr/lib/fcitx5 must stay listed — setting FCITX_ADDON_DIRS *replaces* the
  # default system addon dir, so we re-add it explicitly.
  cat >"$FCITX_DROPIN" <<EOF
[Service]
Environment="FCITX_ADDON_DIRS=%h/.local/share/macro-ime/lib/fcitx5:/usr/lib/fcitx5"
Environment="LIBIME_MODEL_DIRS=%h/.local/share/macro-ime/lib"
EOF
  ok "event addon installed"
}

build_state_addon_to() {
  local dest=$1
  local build_dir
  build_dir=$(mktemp -d)
  note "configuring (cmake)"
  cmake -S "$SRC/engine/macro-ime-state" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null || {
      echo "macro-ime: cmake configure failed" >&2; rm -rf "$build_dir"; return 1; }
  note "compiling libmacro-ime-state.so"
  cmake --build "$build_dir" --parallel >/dev/null || {
      echo "macro-ime: build failed (fcitx5 ABI mismatch?)" >&2; rm -rf "$build_dir"; return 1; }
  install -m 0755 "$build_dir/libmacro-ime-state.so" "$dest"
  rm -rf "$build_dir"
}

# --- runtime + plugins -------------------------------------------------------
install_runtime() {
  mkdir -p "$MACRO_IME_HOME/bin" "$MACRO_IME_HOME/themes"
  install -m 0755 "$SRC/bin/macro-ime-config" "$MACRO_IME_HOME/bin/"
  install -m 0755 "$SRC/themes/macro-ime-theme" "$MACRO_IME_HOME/themes/"
  cp -r "$SRC/themes/template" "$MACRO_IME_HOME/themes/"

  mkdir -p "${HOME}/.config/omarchy/hooks/theme-set.d"
  install -m 0755 "$SRC/themes/hook-theme-set.sh" \
    "${HOME}/.config/omarchy/hooks/theme-set.d/macro-ime.sh"
  ok "runtime files in place"
}

install_plugins() {
  mkdir -p "$PLUGIN_DIR"
  local p staging
  for p in macro-ime.indicator macro-ime.settings; do
    # Preserve any pre-existing plugin dir so --undo can restore it fully
    # (e.g. a user-customized clone from an earlier install).
    if [[ -d "$PLUGIN_DIR/$p" && ! -e "$BACKUP_DIR/plugin-$p" ]]; then
      cp -r "$PLUGIN_DIR/$p" "$BACKUP_DIR/plugin-$p"
      note "backed up existing $p (restored by --undo)"
    fi
    staging="$PLUGIN_DIR/.${p}.install.$$"
    rm -rf "$staging"
    cp -r "$SRC/plugins/$p" "$staging"
    if ! omarchy plugin validate "$staging" >/dev/null; then
      rm -rf "$staging"
      printf '%s    ✗ plugin validation failed for %s%s\n' "$C_R" "$p" "$C_0"
      exit 1
    fi
    rm -rf "${PLUGIN_DIR:?}/$p"
    mv "$staging" "${PLUGIN_DIR:?}/$p"
    ok "installed $p"
  done
  # Record enable state for --undo to restore.
  omarchy plugin list --json >"$BACKUP_DIR/plugin-state.json" 2>/dev/null || true
}

# --- commit phase (fcitx5 stopped for the shortest possible window) ----------
prepare_fcitx_config() {
  local tmp
  note "backing up + editing fcitx5 config"
  mkdir -p "$BACKUP_DIR"
  backup_file_once "$UI_CONF" classicui.conf
  backup_file_once "$CORE_CONF" config
  backup_file_once "$PY_CONF" pinyin.conf

  mkdir -p "$(dirname "$CORE_CONF")"
  [[ -f $CORE_CONF ]] || : >"$CORE_CONF"
  tmp=$(mktemp "$(dirname "$CORE_CONF")/.config.XXXXXX")
  if grep -q '^PreeditEnabledByDefault=' "$CORE_CONF"; then
    sed 's/^PreeditEnabledByDefault=.*/PreeditEnabledByDefault=False/' "$CORE_CONF" >"$tmp"
  elif grep -q '^\[Behavior\]$' "$CORE_CONF"; then
    sed '/^\[Behavior\]$/a PreeditEnabledByDefault=False' "$CORE_CONF" >"$tmp"
  else
    cat "$CORE_CONF" >"$tmp"
    printf '\n[Behavior]\nPreeditEnabledByDefault=False\n' >>"$tmp"
  fi
  mv "$tmp" "$CORE_CONF"
  note "config updated (PreeditEnabledByDefault=False)"

  mkdir -p "$(dirname "$PY_CONF")"
  [[ -f $PY_CONF ]] || : >"$PY_CONF"
  tmp=$(mktemp "$(dirname "$PY_CONF")/.pinyin.XXXXXX")
  if grep -q '^KeepCurrentContext=' "$PY_CONF"; then
    sed 's/^KeepCurrentContext=.*/KeepCurrentContext=False/' "$PY_CONF" >"$tmp"
  else
    cat "$PY_CONF" >"$tmp"
    printf 'KeepCurrentContext=False\n' >>"$tmp"
  fi
  mv "$tmp" "$PY_CONF"
  note "pinyin default: cross-sentence context off (KeepCurrentContext=False)"
}

commit_fcitx_config() {
  stop_fcitx
  prepare_fcitx_config
  commit_language_model
  systemctl --user daemon-reload
  restart_fcitx
  ok "config committed; fcitx5 restarted with LIBIME_MODEL_DIRS + FCITX_ADDON_DIRS"
}

# Post-install verification: the service must run, the addon must load, and
# the state bridge must be writing. Failure here fails the install.
health_check() {
  local journal
  sleep 1
  if ! systemctl --user is-active --quiet omarchy-fcitx5.service; then
    echo "macro-ime: fcitx5 is not active after install (health check 1/3)" >&2
    return 1
  fi
  journal=$(journalctl --user -u omarchy-fcitx5.service --since "2 min ago" 2>/dev/null || true)
  if ! grep -q "Loaded addon macro-ime-state" <<<"$journal"; then
    echo "macro-ime: state addon did not load (health check 2/3)" >&2
    echo "  journal: journalctl --user -u omarchy-fcitx5.service -n 80" >&2
    return 1
  fi
  if [[ ! -s "$RUNTIME_STATE_DIR/state" ]]; then
    echo "macro-ime: state file not written (health check 3/3)" >&2
    echo "  expected: $RUNTIME_STATE_DIR/state" >&2
    return 1
  fi
  ok "health check passed: service active, addon loaded, state file live"
}

apply_and_activate() {
  health_check || return 1

  "$MACRO_IME_HOME/themes/macro-ime-theme"
  ok "theme applied"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 1
  omarchy plugin enable macro-ime.settings >/dev/null 2>&1 || \
    echo "macro-ime: enable settings manually: omarchy plugin enable macro-ime.settings"
  omarchy plugin enable macro-ime.indicator center >/dev/null 2>&1 || \
    echo "macro-ime: add indicator manually: omarchy plugin enable macro-ime.indicator center"
  sleep 2
  omarchy restart shell >/dev/null 2>&1 || true
  # The theme script may have cycled fcitx5 again; confirm it is alive.
  if ! systemctl --user is-active --quiet omarchy-fcitx5.service; then
    echo "macro-ime: fcitx5 is not active after theme application" >&2
    return 1
  fi
}

# --- main --------------------------------------------------------------------
[[ ${1:-} == "--undo" ]] && { undo; exit 0; }

require_commands

# Backup dir is the undo contract; it must exist before any backup_file_once.
mkdir -p "$BACKUP_DIR"

load_version
trap 'on_error $LINENO' ERR

echo "macro-ime: installing Omarchy-native Chinese IME experience (release ${RELEASE_TAG})"

TOTAL=6
step 1 $TOTAL "Preparing language model"
prepare_language_model
step 2 $TOTAL "Installing event addon (libmacro-ime-state.so)"
install_addon
step 3 $TOTAL "Installing runtime files (backend + theme generator)"
install_runtime
step 4 $TOTAL "Installing shell plugins (indicator + settings)"
install_plugins
step 5 $TOTAL "Committing fcitx5 config (stop → edit → restart)"
commit_fcitx_config
step 6 $TOTAL "Applying theme + activating plugins"
apply_and_activate

# Manifest summary for the final report.
LM_MANIFEST_REL=$(jq -r '.release // ""' "$MANIFEST" 2>/dev/null || true)

# Clean up the temp download dir (kept alive through the commit phase).
[[ -n "$LM_DL_DIR" ]] && rm -rf "$LM_DL_DIR"

echo
echo "Macro IME installed (release ${RELEASE_TAG}):"
echo "  language model   ${MACRO_IME_LM_DIR}/${LM_FILENAME} (via LIBIME_MODEL_DIRS)"
echo "                   tracked in ${MANIFEST} (LM release ${LM_MANIFEST_REL:-none})"
echo "  candidate window follows the active omarchy theme"
echo "  bar indicator    event-driven 中/EN · left-click toggle · right-click settings"
echo "  settings panel   fuzzy pairs, correction, vertical list,"
echo "                   user-dict reset — atomic DBus config writes"
echo "  rollback         $0 --undo"