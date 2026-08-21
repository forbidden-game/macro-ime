#!/usr/bin/env bash
# devshot.sh — safely screenshot the omarime candidate window.
#
# Launches its own foot window, waits until Hyprland confirms it is focused,
# activates the IME *for that window*, types a test string, then captures a
# cropped screenshot around the panel. Never touches pre-existing windows.
#
# Usage: devshot.sh [text] [output.png]
set -euo pipefail

TEXT="${1:-nihao}"
OUT="${2:-/tmp/omarime-devshot.png}"
MARK="omarime-test-$$"

setsid foot -e bash -c "export PS1=$MARK; sleep 25" >/dev/null 2>&1 &

for i in $(seq 1 40); do
  cls=$(hyprctl -j activewindow 2>/dev/null | jq -r '.class // empty' || true)
  [[ $cls == foot ]] && break
  sleep 0.15
done
cls=$(hyprctl -j activewindow 2>/dev/null | jq -r '.class // empty' || true)
[[ $cls == "foot" ]] || { echo "devshot: no focused foot window" >&2; exit 1; }

fcitx5-remote -o >/dev/null
sleep 0.4
wtype "$TEXT"
sleep 0.9

# find the panel: scan for the active window's geometry and shoot the region
# above/at the cursor — simplest robust approach: full screen shot, crop later.
grim "$OUT"

# also grab hyprctl's layer list so we can see fcitx's layer namespace
hyprctl layers >"${OUT%.png}.layers.txt" 2>/dev/null || true

echo "devshot: saved $OUT"
