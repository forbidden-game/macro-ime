#!/usr/bin/env bash
# omarime themes installer — Phase A (classicui theme + theme-follow hook)
#
#   ./install.sh          install everything + apply now
#   ./install.sh --undo   full rollback (theme files, hook, classicui keys)
#
# What it does:
#   1. copies the generator + templates to ~/.local/share/omarime/themes/
#   2. installs the theme-set hook so palette changes regenerate the IME theme
#   3. generates the theme from the current Omarchy palette and switches
#      fcitx5 to it (Theme=omarime, fonts, tray colors)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="${HOME}/.local/share/omarime/themes"
HOOK_DST="${HOME}/.config/omarchy/hooks/theme-set.d/omarime.sh"
UI_CONF="${HOME}/.config/fcitx5/conf/classicui.conf"
CORE_CONF="${HOME}/.config/fcitx5/config"
BACKUP_DIR="${HOME}/.local/share/omarime/backup"

restore_file() {
  local backup=$1 destination=$2
  if [[ -f "$BACKUP_DIR/$backup" ]]; then
    mkdir -p "$(dirname "$destination")"
    cp "$BACKUP_DIR/$backup" "$destination"
  elif [[ -f "$BACKUP_DIR/$backup.missing" ]]; then
    rm -f "$destination"
  fi
}

if [[ ${1:-} == "--undo" ]]; then
  was_active=0
  case $(systemctl --user is-active omarchy-fcitx5.service 2>/dev/null || true) in
    active|activating|reloading) was_active=1 ;;
  esac
  pgrep -x fcitx5 >/dev/null 2>&1 && was_active=1
  systemctl --user stop omarchy-fcitx5.service 2>/dev/null || true
  pkill -x fcitx5 2>/dev/null || true
  for _ in {1..20}; do pgrep -x fcitx5 >/dev/null || break; sleep 0.05; done
  pgrep -x fcitx5 >/dev/null && { echo "fcitx5 did not stop" >&2; exit 1; }
  restore_file classicui.conf "$UI_CONF"
  restore_file config "$CORE_CONF"
  systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
  (( was_active )) && systemctl --user start omarchy-fcitx5.service
  rm -rf "$DST" "$HOOK_DST" "$HOME/.local/share/fcitx5/themes/omarime"
  echo "omarime themes: removed; fcitx5 config restored to its pre-install state"
  exit 0
fi

# Backup only once across reinstalls, after stopping fcitx5 so its memory state
# cannot overwrite the copy. Also force preedit into our panel, not app boxes.
was_active=0
case $(systemctl --user is-active omarchy-fcitx5.service 2>/dev/null || true) in
  active|activating|reloading) was_active=1 ;;
esac
pgrep -x fcitx5 >/dev/null 2>&1 && was_active=1
systemctl --user stop omarchy-fcitx5.service 2>/dev/null || true
pkill -x fcitx5 2>/dev/null || true
for _ in {1..20}; do pgrep -x fcitx5 >/dev/null || break; sleep 0.05; done
pgrep -x fcitx5 >/dev/null && { echo "fcitx5 did not stop" >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
[[ -e "$BACKUP_DIR/classicui.conf" || -e "$BACKUP_DIR/classicui.conf.missing" ]] || {
  [[ -f $UI_CONF ]] && cp "$UI_CONF" "$BACKUP_DIR/classicui.conf" || touch "$BACKUP_DIR/classicui.conf.missing"
}
[[ -e "$BACKUP_DIR/config" || -e "$BACKUP_DIR/config.missing" ]] || {
  [[ -f $CORE_CONF ]] && cp "$CORE_CONF" "$BACKUP_DIR/config" || touch "$BACKUP_DIR/config.missing"
}
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
systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
(( was_active )) && systemctl --user start omarchy-fcitx5.service

mkdir -p "$DST"
cp "$SRC/omarime-theme" "$SRC/hook-theme-set.sh" "$DST/"
cp -r "$SRC/template" "$DST/"
chmod +x "$DST/omarime-theme"

mkdir -p "$(dirname "$HOOK_DST")"
cp "$SRC/hook-theme-set.sh" "$HOOK_DST"
chmod +x "$HOOK_DST"

"$DST/omarime-theme"

echo
echo "omarime themes installed:"
echo "  theme      ~/.local/share/fcitx5/themes/omarime (regenerated from current palette)"
echo "  hook       $HOOK_DST  → follows omarchy theme switches"
echo "  regenerate ~/.local/share/omarime/themes/omarime-theme   (tune: --pill-alpha, --radius, …)"
echo "  rollback   $SRC/install.sh --undo"
