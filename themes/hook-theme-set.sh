#!/usr/bin/env bash
# omarime theme-set hook — keep the fcitx5 candidate window on-palette.
# Runs after every `omarchy theme set …` (installed to ~/.config/omarchy/hooks/theme-set.d/).
exec "${HOME}/.local/share/omarime/themes/omarime-theme" --quiet
