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

if [[ ${1:-} == "--undo" ]]; then
  rm -rf "$DST" "$HOOK_DST"
  if systemctl --user is-active --quiet omarchy-fcitx5.service; then
    systemctl --user stop omarchy-fcitx5.service
    sed -i '/^Theme=omarime$/d;/^DarkTheme=omarime$/d' "$UI_CONF" 2>/dev/null || true
    systemctl --user start omarchy-fcitx5.service
  else
    sed -i '/^Theme=omarime$/d;/^DarkTheme=omarime$/d' "$UI_CONF" 2>/dev/null || true
  fi
  echo "omarime themes: removed (fcitx5 back to default theme)"
  exit 0
fi

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
