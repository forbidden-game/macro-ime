#!/usr/bin/env bash
# Macro IME theme-set hook — keep the fcitx5 candidate window on-palette.
# Runs after every `omarchy theme set …` (installed to ~/.config/omarchy/hooks/theme-set.d/).
exec "${HOME}/.local/share/macro-ime/themes/macro-ime-theme" --quiet
