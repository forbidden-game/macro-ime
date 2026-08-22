#!/usr/bin/env bash
# omarime installer — Omarchy-native Chinese IME experience.
#
#   ./install.sh [options]          install everything and apply now
#   ./install.sh --undo             full rollback
#
# Options:
#   --lm-file <path>   path to zh_CN.lm (E6 language model, ~463MB).
#                      If not provided, downloads from the latest GitHub
#                      release of forbidden-game/omarime.
#   --skip-lm          skip LM install (e.g. you already have it, or you
#                      want to install the UI without the engine model).
#   --offline          do not attempt any download; fail if files are missing.
#
# Installs (all under user directories, no root required):
#   ~/.local/share/omarime/lib/zh_CN.lm            language model
#   ~/.local/share/omarime/lib/zh_CN.lm.predict    prediction index
#   ~/.local/share/omarime/lib/fcitx5/libomarime-state.so  event addon
#   ~/.local/share/omarime/bin/omarime-config      settings backend
#   ~/.local/share/omarime/themes/                 theme generator + template
#   ~/.local/share/fcitx5/themes/omarime           generated theme (live)
#   ~/.local/share/fcitx5/addon/omarime-state.conf addon registration
#   ~/.config/fcitx5/...                           fcitx5 config (backed up)
#   ~/.config/omarchy/hooks/theme-set.d/omarime.sh palette follow hook
#   ~/.config/omarchy/plugins/omarime.indicator   bar widget
#   ~/.config/omarchy/plugins/omarime.settings    settings panel
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARIME_HOME="${HOME}/.local/share/omarime"
OMARIME_LIB="${OMARIME_HOME}/lib"
OMARIME_LM_DIR="${OMARIME_LIB}"          # LM files live here
PLUGIN_DIR="${HOME}/.config/omarchy/plugins"
UI_CONF="${HOME}/.config/fcitx5/conf/classicui.conf"
CORE_CONF="${HOME}/.config/fcitx5/config"
PY_CONF="${HOME}/.config/fcitx5/conf/pinyin.conf"
BACKUP_DIR="$OMARIME_HOME/backup"
STATE_ADDON_CONF="${HOME}/.local/share/fcitx5/addon/omarime-state.conf"
FCITX_DROPIN="${HOME}/.config/systemd/user/omarchy-fcitx5.service.d/omarime-state.conf"
RUNTIME_STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/omarime"
GH_REPO="forbidden-game/omarime"
GH_API="https://api.github.com/repos/${GH_REPO}/releases/latest"

LM_FILENAME="zh_CN.lm"
LM_PREDICT_FILENAME="zh_CN.lm.predict"

# --- parse options -----------------------------------------------------------
LM_FILE=""
SKIP_LM=0
OFFLINE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --lm-file)  LM_FILE="${2:?--lm-file requires a path}"; shift 2 ;;
    --skip-lm)  SKIP_LM=1; shift ;;
    --offline)  OFFLINE=1; shift ;;
    --undo)     break ;;   # handled below
    -h|--help)  grep '^#' "$0" | sed 's/^# \?//' | head -20; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# --- progress + error handling -----------------------------------------------
if [[ -t 2 ]]; then C_B=$'\033[1;36m' C_R=$'\033[0;31m' C_G=$'\033[0;32m' C_0=$'\033[0m'
else               C_B= C_R= C_G= C_0=; fi

step() { printf '\n%s==> [%s/%s] %s%s\n' "$C_B" "$1" "$2" "$3" "$C_0"; }
note() { printf '    %s\n' "$1"; }
ok()   { printf '%s    \u2713 %s%s\n' "$C_G" "$1" "$C_0"; }

require_commands() {
  local missing=() c m
  for c in omarchy omarchy-shell; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  pkg-config --exists 'Fcitx5Core >= 5.1' 2>/dev/null || \
    missing+=("Fcitx5Core >= 5.1 (fcitx5 development headers)")
  # cmake + c++ only needed if no pre-built addon is available
  if [[ ! -f "${SRC}/dist/libomarime-state.so" ]]; then
    for c in cmake c++ pkg-config; do
      command -v "$c" >/dev/null || missing+=("$c (needed to build event addon; or provide dist/libomarime-state.so)")
    done
  fi
  if (( ${#missing[@]} )); then
    printf '%s\u2717 omarime: missing required dependencies:%s\n' "$C_R" "$C_0" >&2
    for m in "${missing[@]}"; do printf '    - %s\n' "$m" >&2; done
    printf '  Install them, then re-run: %s\n' "$0" >&2
    exit 1
  fi
}

on_error() {
  local code=$? line=$1
  trap - ERR
  printf '\n%s\u2717 omarime: install failed (exit %s, near line %s).%s\n' \
    "$C_R" "$code" "$line" "$C_0" >&2
  printf '  A partial install may remain on this machine. Roll everything back with:\n' >&2
  printf '      %s --undo\n' "$0" >&2
  exit "$code"
}
trap 'on_error $LINENO' ERR

service_running() {
  case $(systemctl --user is-active omarchy-fcitx5.service 2>/dev/null || true) in
    active|activating|reloading) return 0 ;;
  esac
  pgrep -x fcitx5 >/dev/null 2>&1
}

stop_fcitx() {
  systemctl --user stop omarchy-fcitx5.service 2>/dev/null || true
  pkill -x fcitx5 2>/dev/null || true
  for _ in {1..20}; do pgrep -x fcitx5 >/dev/null || return 0; sleep 0.05; done
  echo "omarime: fcitx5 did not stop" >&2
  return 1
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

undo() {
  local was_active=0
  service_running && was_active=1
  step 1 3 "Stopping fcitx5"
  if ! stop_fcitx; then
    printf '%s\u2717 fcitx5 is still running; aborting undo to protect live files.%s\n' "$C_R" "$C_0" >&2
    printf '  Quit the IM (or wait for fcitx5 to exit), then re-run: %s --undo\n' "$0" >&2
    return 1
  fi
  ok "fcitx5 stopped"
  step 2 3 "Restoring original fcitx5 config"
  restore_file classicui.conf "$UI_CONF"
  restore_file config "$CORE_CONF"
  restore_file pinyin.conf "$PY_CONF"
  ok "config restored"
  step 3 3 "Disabling plugins + removing installed files"
  omarchy plugin disable omarime.indicator >/dev/null 2>&1 || true
  omarchy plugin disable omarime.settings >/dev/null 2>&1 || true
  restore_file state-addon.conf "$STATE_ADDON_CONF"
  restore_file fcitx-dropin.conf "$FCITX_DROPIN"
  rm -rf "$OMARIME_HOME" \
         "$HOME/.local/share/fcitx5/themes/omarime" \
         "$HOME/.config/omarchy/hooks/theme-set.d/omarime.sh" \
         "$PLUGIN_DIR/omarime.indicator" \
         "$PLUGIN_DIR/omarime.settings" \
         "$RUNTIME_STATE_DIR"
  systemctl --user daemon-reload
  if (( was_active )); then
    systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
    systemctl --user start omarchy-fcitx5.service
  fi
  ok "removed; fcitx5 config restored to its pre-install state"
}

[[ ${1:-} == "--undo" ]] && { undo; exit 0; }

# Nothing is touched until every dependency is present.
require_commands

echo "omarime: installing Omarchy-native Chinese IME experience"

TOTAL=6
if (( SKIP_LM )); then TOTAL=5; fi

step 1 $TOTAL "Preparing fcitx5 config"
prepare_fcitx_config

step 2 $TOTAL "Installing language model"
install_language_model

step 3 $TOTAL "Installing event addon (libomarime-state.so)"
install_addon

step 4 $TOTAL "Installing runtime files (backend + theme generator)"
install_runtime

step 5 $TOTAL "Installing shell plugins (indicator + settings)"
install_plugins

step 6 $TOTAL "Applying theme + activating plugins"
apply_and_activate

# --- individual steps ---------------------------------------------------------

prepare_fcitx_config() {
  local was_active=0 tmp
  service_running && was_active=1
  if ! stop_fcitx; then
    echo "omarime: cannot proceed while fcitx5 is still running" >&2
    return 1
  fi
  note "backing up current fcitx5 config"
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
  if (( was_active )); then
    systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
    systemctl --user start omarchy-fcitx5.service
  fi
  ok "fcitx5 config ready"
}

install_language_model() {
  if (( SKIP_LM )); then
    note "skipped (--skip-lm)"
    ok "language model skipped"
    return 0
  fi

  mkdir -p "$OMARIME_LM_DIR"
  local lm_dest="${OMARIME_LM_DIR}/${LM_FILENAME}"
  local predict_dest="${OMARIME_LM_DIR}/${LM_PREDICT_FILENAME}"

  # Already installed?
  if [[ -f "$lm_dest" && -f "$predict_dest" ]]; then
    note "LM already installed at $lm_dest ($(du -h "$lm_dest" | cut -f1))"
    ok "language model in place"
    return 0
  fi

  # Source priority: --lm-file > local dist/ > GitHub Release download
  local lm_src="" predict_src=""

  if [[ -n "$LM_FILE" ]]; then
    # User provided a path; expect .predict alongside it
    lm_src="$LM_FILE"
    predict_src="${lm_src}.predict"
    if [[ ! -f "$lm_src" ]]; then
      echo "omarime: LM file not found: $lm_src" >&2
      return 1
    fi
    note "using LM from: $lm_src"
  elif [[ -f "${SRC}/dist/${LM_FILENAME}" ]]; then
    lm_src="${SRC}/dist/${LM_FILENAME}"
    predict_src="${SRC}/dist/${LM_PREDICT_FILENAME}"
    note "using LM from repo dist/ directory"
  else
    # Download from GitHub Release
    if (( OFFLINE )); then
      echo "omarime: LM file not found locally and --offline is set." >&2
      echo "  Place the LM file at dist/${LM_FILENAME} or use --lm-file <path>" >&2
      return 1
    fi
    note "downloading language model from GitHub Release (~463MB)…"
    lm_src=$(mktemp)
    predict_src=$(mktemp)
    local dl_lm dl_predict
    dl_lm=$(gh_release_asset_url "$LM_FILENAME") || {
      echo "omarime: failed to find LM asset in GitHub Release" >&2
      return 1
    }
    dl_predict=$(gh_release_asset_url "$LM_PREDICT_FILENAME") || {
      echo "omarime: failed to find predict asset in GitHub Release" >&2
      return 1
    }
    curl -fL --progress-bar -o "$lm_src" "$dl_lm" || {
      echo "omarime: LM download failed" >&2
      rm -f "$lm_src"
      return 1
    }
    curl -fL --progress-bar -o "$predict_src" "$dl_predict" || {
      echo "omarime: predict download failed" >&2
      rm -f "$lm_src" "$predict_src"
      return 1
    }
  fi

  # Install
  note "installing to $OMARIME_LM_DIR/"
  cp "$lm_src" "$lm_dest"
  if [[ -f "$predict_src" ]]; then
    cp "$predict_src" "$predict_dest"
  fi

  # Clean up temp files (but not if they're in dist/)
  if [[ "$lm_src" != "${SRC}/dist/"* && "$lm_src" != "$LM_FILE" ]]; then
    rm -f "$lm_src" "$predict_src"
  fi

  ok "language model installed ($(du -h "$lm_dest" | cut -f1))"
}

gh_release_asset_url() {
  local name=$1
  curl -fsSL "$GH_API" | jq -r ".assets[] | select(.name == \"${name}\") | .browser_download_url"
}

install_addon() {
  local addon_dest="${OMARIME_LIB}/fcitx5/libomarime-state.so"
  mkdir -p "$(dirname "$addon_dest")" "$(dirname "$STATE_ADDON_CONF")" \
           "$(dirname "$FCITX_DROPIN")"

  backup_file_once "$STATE_ADDON_CONF" state-addon.conf
  backup_file_once "$FCITX_DROPIN" fcitx-dropin.conf

  if [[ -f "${SRC}/dist/libomarime-state.so" ]]; then
    # Pre-built addon (from CI or local build)
    install -m 0755 "${SRC}/dist/libomarime-state.so" "$addon_dest"
    note "installed pre-built addon"
  else
    # Build from source
    if ! command -v cmake >/dev/null; then
      echo "omarime: no pre-built addon in dist/ and cmake not available." >&2
      echo "  Build it with: cmake -S engine/omarime-state -B build && cmake --build build" >&2
      return 1
    fi
    build_state_addon_to "$addon_dest"
  fi

  # Register addon + set LIBIME_MODEL_DIRS in systemd drop-in
  # (the conf.in is configured by cmake; generate it manually for the
  #  pre-built path)
  local fcitx_ver
  fcitx_ver=$(pkg-config --modversion Fcitx5Core 2>/dev/null || echo "unknown")
  cat >"$STATE_ADDON_CONF" <<EOF
[Addon]
Name=omarime-state
Description=omarime event bridge (writes IM state to runtime dir)
Version=${fcitx_ver}
Library=omarime-state
Type=SharedLibrary
OnDemand=False
EOF

  cat >"$FCITX_DROPIN" <<EOF
[Service]
Environment="FCITX_ADDON_DIRS=%h/.local/share/omarime/lib/fcitx5:/usr/lib/fcitx5"
Environment="LIBIME_MODEL_DIRS=%h/.local/share/omarime/lib"
EOF
  systemctl --user daemon-reload
  ok "event addon installed"
}

build_state_addon_to() {
  local dest=$1
  local build_dir
  build_dir=$(mktemp -d)
  trap 'rm -rf "$build_dir"' RETURN
  note "configuring (cmake)"
  cmake -S "$SRC/engine/omarime-state" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null || {
      echo "omarime: cmake configure failed" >&2; return 1; }
  note "compiling libomarime-state.so"
  cmake --build "$build_dir" --parallel >/dev/null || {
      echo "omarime: build failed (fcitx5 ABI mismatch?)" >&2; return 1; }
  install -m 0755 "$build_dir/libomarime-state.so" "$dest"
  rm -rf "$build_dir"
}

install_runtime() {
  mkdir -p "$OMARIME_HOME/bin" "$OMARIME_HOME/themes"
  install -m 0755 "$SRC/bin/omarime-config" "$OMARIME_HOME/bin/"
  install -m 0755 "$SRC/themes/omarime-theme" "$OMARIME_HOME/themes/"
  cp -r "$SRC/themes/template" "$OMARIME_HOME/themes/"

  mkdir -p "${HOME}/.config/omarchy/hooks/theme-set.d"
  install -m 0755 "$SRC/themes/hook-theme-set.sh" \
    "${HOME}/.config/omarchy/hooks/theme-set.d/omarime.sh"
  ok "runtime files in place"
}

install_plugins() {
  mkdir -p "$PLUGIN_DIR"
  for p in omarime.indicator omarime.settings; do
    staging="$PLUGIN_DIR/.${p}.install.$$"
    rm -rf "$staging"
    cp -r "$SRC/plugins/$p" "$staging"
    if ! omarchy plugin validate "$staging" >/dev/null; then
      rm -rf "$staging"
      printf '%s    \u2717 plugin validation failed for %s%s\n' \
        "$C_R" "$p" "$C_0"
      exit 1
    fi
    rm -rf "$PLUGIN_DIR/$p"
    mv "$staging" "$PLUGIN_DIR/$p"
    ok "installed $p"
  done
}

apply_and_activate() {
  "$OMARIME_HOME/themes/omarime-theme"
  ok "theme applied"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 1
  omarchy plugin enable omarime.settings >/dev/null 2>&1 || \
    echo "omarime: enable settings manually: omarchy plugin enable omarime.settings"
  omarchy plugin enable omarime.indicator center >/dev/null 2>&1 || \
    echo "omarime: add indicator manually: omarchy plugin enable omarime.indicator center"
  sleep 2
  omarchy restart shell >/dev/null 2>&1 || true
}

backup_file_once() {
  local source=$1 backup=$2
  [[ -e "$BACKUP_DIR/$backup" || -e "$BACKUP_DIR/$backup.missing" ]] && return
  if [[ -f $source ]]; then cp "$source" "$BACKUP_DIR/$backup"
  else touch "$BACKUP_DIR/$backup.missing"
  fi
}

# --- final summary -----------------------------------------------------------
echo
echo "omarime installed:"
echo "  language model   ${OMARIME_LM_DIR}/${LM_FILENAME} (via LIBIME_MODEL_DIRS)"
echo "  candidate window follows the active omarchy theme"
echo "  bar indicator    event-driven 中/EN · left-click toggle · right-click settings"
echo "  settings panel   fuzzy pairs, correction, vertical list, cloud pinyin,"
echo "                   user-dict reset — atomic DBus config writes"
echo "  rollback         $SRC/install.sh --undo"
