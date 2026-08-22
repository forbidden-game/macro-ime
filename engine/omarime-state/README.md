# omarime-state

Small fcitx5 module that turns input-context events into an event-driven state
file for the Omarchy bar.

It watches `InputContextInputMethodActivated`,
`InputContextInputMethodDeactivated`, `InputContextSwitchInputMethod`, and
`InputContextFocusIn` at the public `Default` phase, then writes:

```text
$XDG_RUNTIME_DIR/omarime/state   # 0=unavailable, 1=English, 2=Pinyin
```

The full installer builds the module against the installed fcitx5 ABI and adds
a user systemd drop-in with its private addon library directory. Nothing is
installed under `/usr`.
