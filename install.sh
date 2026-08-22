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
#   ~/.config/omarchy/hooks/theme-set.d/omarime.sh  palette follows omarchy themes
#   ~/.config/omarchy/plugins/omarime.indicator    中/EN bar widget (+OSD toast)
#   ~/.config/omarchy/plugins/omarime.settings     settings panel (right-click widget)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARIME_HOME="${HOME}/.local/share/omarime"
PLUGIN_DIR="${HOME}/.config/omarchy/plugins"
UI_CONF="${HOME}/.config/fcitx5/conf/classicui.conf"
CORE_CONF="${HOME}/.config/fcitx5/config"
BACKUP_DIR="$OMARIME_HOME/backup"

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
  stop_fcitx
  restore_file classicui.conf "$UI_CONF"
  restore_file config "$CORE_CONF"
  if (( was_active )); then
    systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
    systemctl --user start omarchy-fcitx5.service
  fi

  # Remove shell.json references while the manifests are still discoverable.
  omarchy plugin disable omarime.indicator >/dev/null 2>&1 || true
  omarchy plugin disable omarime.settings >/dev/null 2>&1 || true

  rm -rf "$OMARIME_HOME" \
         "$HOME/.local/share/fcitx5/themes/omarime" \
         "$HOME/.config/omarchy/hooks/theme-set.d/omarime.sh" \
         "$PLUGIN_DIR/omarime.indicator" \
         "$PLUGIN_DIR/omarime.settings"
  echo "omarime: removed; fcitx5 config restored to its pre-install state"
}

backup_file_once() { # backup_file_once <source> <backup-name>
  local source=$1 backup=$2
  [[ -e "$BACKUP_DIR/$backup" || -e "$BACKUP_DIR/$backup.missing" ]] && return
  if [[ -f $source ]]; then cp "$source" "$BACKUP_DIR/$backup"
  else touch "$BACKUP_DIR/$backup.missing"
  fi
}

prepare_fcitx_config() {
  local was_active=0 tmp
  service_running && was_active=1
  stop_fcitx

  mkdir -p "$BACKUP_DIR"
  backup_file_once "$UI_CONF" classicui.conf
  backup_file_once "$CORE_CONF" config

  mkdir -p "$(dirname "$CORE_CONF")"
  [[ -f $CORE_CONF ]] || : >"$CORE_CONF"
  tmp=$(mktemp)
  if grep -q '^PreeditEnabledByDefault=' "$CORE_CONF"; then
    sed 's/^PreeditEnabledByDefault=.*/PreeditEnabledByDefault=False/' "$CORE_CONF" >"$tmp"
  elif grep -q '^\[Behavior\]$' "$CORE_CONF"; then
    sed '/^\[Behavior\]$/a PreeditEnabledByDefault=False' "$CORE_CONF" >"$tmp"
  else
    cat "$CORE_CONF" >"$tmp"
    printf '\n[Behavior]\nPreeditEnabledByDefault=False\n' >>"$tmp"
  fi
  mv "$tmp" "$CORE_CONF"

  if (( was_active )); then
    systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
    systemctl --user start omarchy-fcitx5.service
  fi
  return 0
}

[[ ${1:-} == "--undo" ]] && { undo; exit 0; }

# Back up first, then make preedit part of our panel instead of an app-drawn box.
prepare_fcitx_config

# 1. runtime files ------------------------------------------------------------
mkdir -p "$OMARIME_HOME/bin" "$OMARIME_HOME/themes"
install -m 0755 "$SRC/bin/omarime-config" "$OMARIME_HOME/bin/"
install -m 0755 "$SRC/themes/omarime-theme" "$OMARIME_HOME/themes/"
cp -r "$SRC/themes/template" "$OMARIME_HOME/themes/"

mkdir -p "${HOME}/.config/omarchy/hooks/theme-set.d"
install -m 0755 "$SRC/themes/hook-theme-set.sh" \
  "${HOME}/.config/omarchy/hooks/theme-set.d/omarime.sh"

# 2. shell plugins ------------------------------------------------------------
mkdir -p "$PLUGIN_DIR"
for p in omarime.indicator omarime.settings; do
  staging="$PLUGIN_DIR/.${p}.install.$$"
  rm -rf "$staging"
  cp -r "$SRC/plugins/$p" "$staging"
  omarchy plugin validate "$staging" >/dev/null || {
    rm -rf "$staging"
    echo "omarime: plugin validation failed for $p" >&2; exit 1; }
  rm -rf "$PLUGIN_DIR/$p"
  mv "$staging" "$PLUGIN_DIR/$p"
done

# 3. generate + apply the theme (also switches classicui Theme= safely) -------
"$OMARIME_HOME/themes/omarime-theme"

# 4. plugin activation + bar placement (enable is idempotent) -----------------
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
echo "  bar indicator      中/EN · left-click toggles · right-click opens settings"
echo "  settings panel     fuzzy pairs, correction, vertical list, cloud pinyin,"
echo "                     user-dict reset — atomic DBus config writes"
echo "  rollback           $SRC/install.sh --undo"
