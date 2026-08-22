#!/usr/bin/env bash
# omarime installer — Omarchy-native Chinese IME experience.
#
#   ./install.sh          install everything and apply now
#   ./install.sh --undo   full rollback
#
# Installs:
#   ~/.local/share/omarime/themes/omarime-theme   classicui theme generator
#   ~/.local/share/fcitx5/themes/omarime          generated theme (live)
#   ~/.local/share/omarime/bin/omarime-config     settings backend (live-reload)
#   ~/.local/share/omarime/lib/fcitx5/             event-driven state addon
#   ~/.config/omarchy/hooks/theme-set.d/omarime.sh  palette follows omarchy themes
#   ~/.config/omarchy/plugins/omarime.indicator    中/EN bar widget
#   ~/.config/omarchy/plugins/omarime.settings     settings panel (right-click widget)
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARIME_HOME="${HOME}/.local/share/omarime"
PLUGIN_DIR="${HOME}/.config/omarchy/plugins"
UI_CONF="${HOME}/.config/fcitx5/conf/classicui.conf"
CORE_CONF="${HOME}/.config/fcitx5/config"
PY_CONF="${HOME}/.config/fcitx5/conf/pinyin.conf"
BACKUP_DIR="$OMARIME_HOME/backup"
STATE_ADDON_CONF="${HOME}/.local/share/fcitx5/addon/omarime-state.conf"
FCITX_DROPIN="${HOME}/.config/systemd/user/omarchy-fcitx5.service.d/omarime-state.conf"
RUNTIME_STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/omarime"

# --- progress + error handling -----------------------------------------------
# Colors only when stderr is a real terminal, so piped/CI logs stay clean.
if [[ -t 2 ]]; then C_B=$'\033[1;36m' C_R=$'\033[0;31m' C_G=$'\033[0;32m' C_0=$'\033[0m'
else               C_B= C_R= C_G= C_0=; fi

step() { printf '\n%s==> [%s/%s] %s%s\n' "$C_B" "$1" "$2" "$3" "$C_0"; }  # step n total title
note() { printf '    %s\n' "$1"; }
ok()   { printf '%s    \u2713 %s%s\n' "$C_G" "$1" "$C_0"; }

# Fail fast, before anything is touched: a missing dependency must not leave a
# half-applied install behind.
require_commands() {
  local missing=() c m
  for c in cmake c++ pkg-config omarchy omarchy-shell; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  pkg-config --exists 'Fcitx5Core >= 5.1' 2>/dev/null || \
    missing+=("Fcitx5Core >= 5.1 development headers")
  if (( ${#missing[@]} )); then
    printf '%s\u2717 omarime: missing required dependencies:%s\n' "$C_R" "$C_0" >&2
    for m in "${missing[@]}"; do printf '    - %s\n' "$m" >&2; done
    printf '  Install them, then re-run: %s\n' "$0" >&2
    exit 1
  fi
}

on_error() {  # ERR trap: locate the failure and point at rollback.
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

restore_file() { # restore_file <backup-name> <destination>
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
  # Remove shell.json references while the manifests are still discoverable.
  omarchy plugin disable omarime.indicator >/dev/null 2>&1 || true
  omarchy plugin disable omarime.settings >/dev/null 2>&1 || true
  # Restore any files that occupied our addon/drop-in paths before install.
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

backup_file_once() { # backup_file_once <source> <backup-name>
  local source=$1 backup=$2
  [[ -e "$BACKUP_DIR/$backup" || -e "$BACKUP_DIR/$backup.missing" ]] && return
  if [[ -f $source ]]; then cp "$source" "$BACKUP_DIR/$backup"
  else touch "$BACKUP_DIR/$backup.missing"
  fi
}

build_state_addon() {
  local build_dir
  for command in cmake c++ pkg-config; do
    command -v "$command" >/dev/null || {
      echo "omarime: missing build dependency: $command" >&2; return 1; }
  done
  pkg-config --exists 'Fcitx5Core >= 5.1' || {
    echo "omarime: Fcitx5Core development files are required" >&2; return 1; }

  build_dir=$(mktemp -d)
  trap 'rm -rf "$build_dir"' RETURN
  note "configuring (cmake)"
  cmake -S "$SRC/engine/omarime-state" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null || {
      echo "omarime: cmake configure failed" >&2; return 1; }
  note "compiling libomarime-state.so"
  cmake --build "$build_dir" --parallel >/dev/null || {
      echo "omarime: build failed (fcitx5 ABI mismatch?)" >&2; return 1; }

  mkdir -p "$OMARIME_HOME/lib/fcitx5" "$(dirname "$STATE_ADDON_CONF")" \
           "$(dirname "$FCITX_DROPIN")"
  backup_file_once "$STATE_ADDON_CONF" state-addon.conf
  backup_file_once "$FCITX_DROPIN" fcitx-dropin.conf
  install -m 0755 "$build_dir/libomarime-state.so" \
    "$OMARIME_HOME/lib/fcitx5/libomarime-state.so"
  install -m 0644 "$build_dir/omarime-state.conf" "$STATE_ADDON_CONF"
  cat >"$FCITX_DROPIN" <<EOF
[Service]
Environment="FCITX_ADDON_DIRS=%h/.local/share/omarime/lib/fcitx5:/usr/lib/fcitx5"
EOF
  systemctl --user daemon-reload
  rm -rf "$build_dir"
}

prepare_fcitx_config() {
  local was_active=0 tmp
  service_running && was_active=1
  step 1 5 "Preparing fcitx5 config"
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
  # Same directory as the target so the final mv is an atomic rename, not a
  # cross-device copy that could corrupt the config if it fails halfway.
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

  # Pinyin addon: omarime ships with cross-sentence context OFF so the same
  # input always yields the same candidates (intra-sentence context stays on,
  # it is a separate, always-active path). Re-enable from the settings panel.
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
  return 0
}

[[ ${1:-} == "--undo" ]] && { undo; exit 0; }

# Nothing is touched until every dependency is present.
require_commands

echo "omarime: installing Omarchy-native Chinese IME experience"

# 1. config — back up first, then make preedit part of our panel instead of an
#    app-drawn box.
prepare_fcitx_config

# 2. runtime files ------------------------------------------------------------
step 2 5 "Installing runtime files (backend + theme generator)"
mkdir -p "$OMARIME_HOME/bin" "$OMARIME_HOME/themes"
install -m 0755 "$SRC/bin/omarime-config" "$OMARIME_HOME/bin/"
install -m 0755 "$SRC/themes/omarime-theme" "$OMARIME_HOME/themes/"
cp -r "$SRC/themes/template" "$OMARIME_HOME/themes/"

mkdir -p "${HOME}/.config/omarchy/hooks/theme-set.d"
install -m 0755 "$SRC/themes/hook-theme-set.sh" \
  "${HOME}/.config/omarchy/hooks/theme-set.d/omarime.sh"
ok "runtime files in place"

# 3. event bridge — build against this machine's fcitx5 ABI. The theme apply
#    below restarts fcitx5 once, which loads the new addon and systemd env.
step 3 5 "Building event bridge (libomarime-state.so)"
build_state_addon
ok "addon built + installed"

# 4. shell plugins ------------------------------------------------------------
step 4 5 "Installing shell plugins (indicator + settings)"
mkdir -p "$PLUGIN_DIR"
for p in omarime.indicator omarime.settings; do
  staging="$PLUGIN_DIR/.${p}.install.$$"
  rm -rf "$staging"
  cp -r "$SRC/plugins/$p" "$staging"
  if ! omarchy plugin validate "$staging" >/dev/null; then
    rm -rf "$staging"
    printf '%s    \u2717 plugin validation failed for %s (source repo problem; nothing installed yet)%s\n' \
      "$C_R" "$p" "$C_0"
    exit 1
  fi
  rm -rf "$PLUGIN_DIR/$p"
  mv "$staging" "$PLUGIN_DIR/$p"
  ok "installed $p"
done

# 5. theme + activate ---------------------------------------------------------
step 5 5 "Applying theme + activating plugins"
"$OMARIME_HOME/themes/omarime-theme"
ok "theme applied"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 1
omarchy plugin enable omarime.settings >/dev/null 2>&1 || \
  echo "omarime: enable settings manually: omarchy plugin enable omarime.settings"
omarchy plugin enable omarime.indicator center >/dev/null 2>&1 || \
  echo "omarime: add indicator manually: omarchy plugin enable omarime.indicator center"
# Current Omarchy logs local-plugin reloads but does not replace live bar-widget
# instances; a shell restart is the only reliable first-install activation.
# Let asynchronous menu incubation finish first so restart stays warning-free.
sleep 2
omarchy restart shell >/dev/null 2>&1 || true

echo
echo "omarime installed:"
echo "  candidate window   follows the active omarchy theme (hook regenerates on switch)"
echo "  bar indicator      event-driven 中/EN · left-click toggle · right-click settings"
echo "  settings panel     fuzzy pairs, correction, vertical list, cloud pinyin,"
echo "                     user-dict reset — atomic DBus config writes"
echo "  rollback           $SRC/install.sh --undo"
