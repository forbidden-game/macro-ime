#!/usr/bin/env bash
# omarime installer — Omarchy-native Chinese IME experience.
#
#   ./install.sh [options]          install everything and apply now
#   ./install.sh --undo             full rollback
#
# Options:
#   --lm-file <path>   path to zh_CN.lm (E6 language model, ~463MB).
#                      If not provided, downloads from the pinned GitHub
#                      release (see the VERSION file).
#   --skip-lm          skip LM install (UI only, no engine model).
#   --offline          do not download; fail if the LM is missing locally.
#
# All files go under user directories — no root, no /usr modification.
# The LM is loaded via the LIBIME_MODEL_DIRS env var (systemd drop-in),
# never by overwriting a system file.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARIME_HOME="${HOME}/.local/share/omarime"
OMARIME_LIB="${OMARIME_HOME}/lib"
OMARIME_LM_DIR="${OMARIME_LIB}"
PLUGIN_DIR="${HOME}/.config/omarchy/plugins"
UI_CONF="${HOME}/.config/fcitx5/conf/classicui.conf"
CORE_CONF="${HOME}/.config/fcitx5/config"
PY_CONF="${HOME}/.config/fcitx5/conf/pinyin.conf"
BACKUP_DIR="$OMARIME_HOME/backup"
STATE_ADDON_CONF="${HOME}/.local/share/fcitx5/addon/omarime-state.conf"
FCITX_DROPIN="${HOME}/.config/systemd/user/omarchy-fcitx5.service.d/omarime-state.conf"
RUNTIME_STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/omarime"
GH_REPO="forbidden-game/omarime"

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

# --- functions (all defined before use) --------------------------------------

require_commands() {
  local missing=() c
  for c in omarchy omarchy-shell; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  # fcitx5 runtime (the IME framework): binary, or the Omarchy user unit.
  if ! command -v fcitx5 >/dev/null && \
     [[ ! -f "${HOME}/.config/systemd/user/omarchy-fcitx5.service" ]]; then
    missing+=("fcitx5 (the IME framework; expected via omarchy-fcitx5.service)")
  fi
  # Build tools only when we actually have to compile the addon from source.
  if [[ ! -f "${SRC}/dist/libomarime-state.so" ]]; then
    pkg-config --exists 'Fcitx5Core >= 5.1' 2>/dev/null || \
      missing+=("Fcitx5Core >= 5.1 (fcitx5 dev headers — to build the addon)")
    for c in cmake c++; do
      command -v "$c" >/dev/null || \
        missing+=("$c (to build the addon; or provide dist/libomarime-state.so)")
    done
  fi
  if (( ${#missing[@]} )); then
    printf '%s✗ omarime: missing required dependencies:%s\n' "$C_R" "$C_0" >&2
    for m in "${missing[@]}"; do printf '    - %s\n' "$m" >&2; done
    printf '  Install them, then re-run: %s\n' "$0" >&2
    exit 1
  fi
}

on_error() {
  local code=$? line=$1
  trap - ERR
  printf '\n%s✗ omarime: install failed (exit %s, near line %s).%s\n' \
    "$C_R" "$code" "$line" "$C_0" >&2
  printf '  A partial install may remain on this machine. Roll everything back with:\n' >&2
  printf '      %s --undo\n' "$0" >&2
  exit "$code"
}

service_running() {
  case $(systemctl --user is-active omarchy-fcitx5.service 2>/dev/null || true) in
    active|activating|reloading) return 0 ;;
  esac
  pgrep -x fcitx5 >/dev/null 2>&1
}

stop_fcitx() {
  systemctl --user stop omarchy-fcitx5.service 2>/dev/null || true
  pkill -x fcitx5 2>/dev/null || true
  # The 463MB LM is memory-mapped; give the process time to unmap + exit.
  for _ in {1..150}; do pgrep -x fcitx5 >/dev/null || return 0; sleep 0.1; done
  echo "omarime: fcitx5 did not stop within 15s" >&2
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

backup_file_once() {
  local source=$1 backup=$2
  [[ -e "$BACKUP_DIR/$backup" || -e "$BACKUP_DIR/$backup.missing" ]] && return
  if [[ -f $source ]]; then cp "$source" "$BACKUP_DIR/$backup"
  else touch "$BACKUP_DIR/$backup.missing"
  fi
}

undo() {
  local was_active=0
  service_running && was_active=1
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

prepare_fcitx_config() {
  local tmp
  stop_fcitx
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
  # fcitx5 stays stopped here. It is (re)started once, at the end, after the
  # systemd drop-in is in place, so the new env vars actually take effect.
  ok "fcitx5 config ready (service stays stopped until the final step)"
}

load_version() {
  VERSION="$(cat "${SRC}/VERSION" 2>/dev/null || true)"
  if [[ -z "$VERSION" ]]; then
    echo "omarime: no VERSION file in ${SRC}; cannot pin engine assets." >&2
    echo "  Create ${SRC}/VERSION with the release version (e.g. 0.1.0)." >&2
    exit 1
  fi
  RELEASE_TAG="v${VERSION}"
}

# sha256 of a release asset, from GitHub's recorded digest. Empty on failure.
gh_release_digest() {
  local name=$1
  gh api "repos/${GH_REPO}/releases/tags/${RELEASE_TAG}" \
    --jq ".assets[] | select(.name == \"${name}\") | .digest // \"\" | sub(\"^sha256:\"; \"\")" \
    2>/dev/null || true
}

verify_lm_integrity() {
  local file=$1 expected=$2 label=$3
  local actual size
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    echo "omarime: sha256 mismatch for ${label}" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
  size=$(stat -c%s "$file")
  if [[ "$label" == "$LM_FILENAME" && "$size" -lt 100000000 ]]; then
    echo "omarime: ${label} is only ${size} bytes (expected ~463MB); looks truncated" >&2
    return 1
  fi
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

  if [[ -f "$lm_dest" && -f "$predict_dest" ]]; then
    note "LM already installed at $lm_dest ($(du -h "$lm_dest" | cut -f1))"
    ok "language model in place"
    return 0
  fi

  local lm_src="" predict_src="" dl_dir=""
  local exp_lm="" exp_pred=""

  if [[ -n "$LM_FILE" ]]; then
    lm_src="$LM_FILE"
    predict_src="${lm_src}.predict"
    if [[ ! -f "$lm_src" ]]; then
      echo "omarime: LM file not found: $lm_src" >&2
      return 1
    fi
    if [[ ! -f "$predict_src" ]]; then
      note "warning: no ${LM_PREDICT_FILENAME} next to $lm_src — cloud-pinyin prediction will be off"
    fi
    note "using LM from: $lm_src"
  elif [[ -f "${SRC}/dist/${LM_FILENAME}" ]]; then
    lm_src="${SRC}/dist/${LM_FILENAME}"
    predict_src="${SRC}/dist/${LM_PREDICT_FILENAME}"
    if [[ ! -f "$predict_src" ]]; then
      note "warning: no ${LM_PREDICT_FILENAME} in dist/ — cloud-pinyin prediction will be off"
    fi
    note "using LM from repo dist/ directory"
  else
    if (( OFFLINE )); then
      echo "omarime: LM not found locally and --offline is set." >&2
      echo "  Place it at dist/${LM_FILENAME} or use --lm-file <path>" >&2
      return 1
    fi
    if ! command -v gh >/dev/null; then
      echo "omarime: 'gh' CLI is required to download the language model from the" >&2
      echo "  private release. Run 'gh auth login' first, or use --lm-file <path>." >&2
      return 1
    fi
    dl_dir=$(mktemp -d)
    note "downloading language model from release ${RELEASE_TAG} (~463MB)…"
    gh release download "$RELEASE_TAG" --repo "$GH_REPO" \
      --pattern "$LM_FILENAME" --pattern "$LM_PREDICT_FILENAME" --dir "$dl_dir" \
      2>/dev/null || {
      echo "omarime: download from ${RELEASE_TAG} failed." >&2
      echo "  Check the release exists + your gh auth, or use --lm-file." >&2
      rm -rf "$dl_dir"; return 1
    }
    lm_src="${dl_dir}/${LM_FILENAME}"
    predict_src="${dl_dir}/${LM_PREDICT_FILENAME}"
    if [[ ! -f "$lm_src" ]]; then
      echo "omarime: LM file missing after download" >&2
      rm -rf "$dl_dir"; return 1
    fi
    # Integrity: verify against the release's recorded sha256 digest.
    exp_lm=$(gh_release_digest "$LM_FILENAME")
    exp_pred=$(gh_release_digest "$LM_PREDICT_FILENAME")
    if ! verify_lm_integrity "$lm_src" "$exp_lm" "$LM_FILENAME"; then
      rm -rf "$dl_dir"; return 1
    fi
    if [[ -f "$predict_src" ]]; then
      if ! verify_lm_integrity "$predict_src" "$exp_pred" "$LM_PREDICT_FILENAME"; then
        rm -rf "$dl_dir"; return 1
      fi
    fi
  fi

  # Size sanity for all paths (download path already verified sha256 above).
  verify_lm_integrity "$lm_src" "" "$LM_FILENAME" || return 1

  note "installing to $OMARIME_LM_DIR/"
  cp "$lm_src" "$lm_dest"
  if [[ -f "$predict_src" ]]; then
    cp "$predict_src" "$predict_dest"
  fi

  # Only remove a temp download dir we created — never dist/ or --lm-file.
  [[ -n "$dl_dir" ]] && rm -rf "$dl_dir"

  ok "language model installed ($(du -h "$lm_dest" | cut -f1))"
}

install_addon() {
  local addon_dest="${OMARIME_LIB}/fcitx5/libomarime-state.so"
  mkdir -p "$(dirname "$addon_dest")" "$(dirname "$STATE_ADDON_CONF")" \
           "$(dirname "$FCITX_DROPIN")"

  backup_file_once "$STATE_ADDON_CONF" state-addon.conf
  backup_file_once "$FCITX_DROPIN" fcitx-dropin.conf

  if [[ -f "${SRC}/dist/libomarime-state.so" ]]; then
    install -m 0755 "${SRC}/dist/libomarime-state.so" "$addon_dest"
    note "installed pre-built addon"
  else
    if ! command -v cmake >/dev/null; then
      echo "omarime: no pre-built addon in dist/ and cmake not available." >&2
      echo "  Build it: cmake -S engine/omarime-state -B build && cmake --build build" >&2
      return 1
    fi
    build_state_addon_to "$addon_dest"
  fi

  # Register the addon. NOTE: fcitx5 resolves the library as name + ".so" and
  # does NOT prepend "lib", so Library= must be the exact .so name minus ".so".
  cat >"$STATE_ADDON_CONF" <<EOF
[Addon]
Name=omarime-state
Comment=omarime event bridge (writes IM state to runtime dir)
Type=SharedLibrary
Library=libomarime-state
Category=Module
Version=${VERSION}
OnDemand=False
EOF

  # Drop-in: point libime at our LM dir and fcitx5 at our addon lib dir.
  # /usr/lib/fcitx5 must stay listed — setting FCITX_ADDON_DIRS *replaces* the
  # default system addon dir, so we re-add it explicitly.
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
  note "configuring (cmake)"
  cmake -S "$SRC/engine/omarime-state" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null || {
      echo "omarime: cmake configure failed" >&2; rm -rf "$build_dir"; return 1; }
  note "compiling libomarime-state.so"
  cmake --build "$build_dir" --parallel >/dev/null || {
      echo "omarime: build failed (fcitx5 ABI mismatch?)" >&2; rm -rf "$build_dir"; return 1; }
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
  local p staging
  for p in omarime.indicator omarime.settings; do
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
}

apply_and_activate() {
  # Restart fcitx first so it loads the LM dir + state addon with the new env.
  if (( FCITX_WAS_ACTIVE )); then
    systemctl --user restart omarchy-fcitx5.service 2>/dev/null || \
      systemctl --user start omarchy-fcitx5.service 2>/dev/null || true
    note "fcitx5 restarted (LIBIME_MODEL_DIRS + FCITX_ADDON_DIRS active)"
  else
    note "fcitx5 was not running — start it later with:"
    note "  systemctl --user start omarchy-fcitx5.service"
  fi
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

# --- main --------------------------------------------------------------------
[[ ${1:-} == "--undo" ]] && { undo; exit 0; }

require_commands

load_version

trap 'on_error $LINENO' ERR

FCITX_WAS_ACTIVE=0
service_running && FCITX_WAS_ACTIVE=1

echo "omarime: installing Omarchy-native Chinese IME experience (release ${RELEASE_TAG})"

TOTAL=6
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

echo
echo "omarime installed (release ${RELEASE_TAG}):"
echo "  language model   ${OMARIME_LM_DIR}/${LM_FILENAME} (via LIBIME_MODEL_DIRS)"
echo "  candidate window follows the active omarchy theme"
echo "  bar indicator    event-driven 中/EN · left-click toggle · right-click settings"
echo "  settings panel   fuzzy pairs, correction, vertical list, cloud pinyin,"
echo "                   user-dict reset — atomic DBus config writes"
echo "  rollback         $0 --undo"
