import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Ui
import qs.Commons

// 中/EN input method indicator for the omarchy bar.
//
// Reads fcitx5's active state (fcitx5-remote: 1 inactive / 2 active) and
// renders the same 中/A convention as the fcitx5 tray icon, in desktop
// tokens: 中 in accent while composing, A dimmed while in English mode.
// Click toggles, exactly like Ctrl+Space; a flip raises an omarchy OSD.
//
// fcitx5 exposes no active-state signal anywhere on the bus (Controller1 is
// methods-only), so the reading is event-driven where it can be: focus
// changes are when per-program state moves (ShareInputState=PerProgram), so
// Hyprland's activewindow events trigger a refresh, with a short poll as the
// safety net and an immediate re-read after a click.

BarWidget {
  id: root
  moduleName: "omarime.indicator"

  // per-widget shell.json overrides: {"pollMs": 2000, "toast": true}
  readonly property int pollMs: root.setting("pollMs", 2000)
  readonly property bool toastEnabled: root.setting("toast", true)

  // fcitx5-remote state: 0 not running, 1 inactive, 2 active
  property int imState: 0
  readonly property bool imActive: imState === 2
  readonly property bool imRunning: imState > 0

  // Announcements compare against the last value the OSD spoke for, so the
  // very first reading fills the label silently instead of announcing a
  // state nobody changed.
  property int lastAnnounced: -1

  // A click lands on the state the next reading will confirm; queue a re-read
  // if one is already in flight rather than trusting the pre-toggle value.
  property bool refreshPending: false

  function refresh() {
    if (queryProc.running) {
      refreshPending = true
      return
    }
    refreshPending = false
    queryProc.running = true
  }

  function toast() {
    if (!toastEnabled || !root.bar) return
    // Direct shell IPC (~40ms) instead of the omarchy osd wrapper chain.
    const payload = JSON.stringify({
      icon: root.imActive ? "中" : "A",
      message: root.imActive ? "中文输入法" : "英文",
      value: "", progressText: "", max: "100", duration: "1200"
    })
    root.bar.run("omarchy-shell -q osd show " + Util.shellQuote(payload))
  }

  onImStateChanged: {
    // Only 1↔2 flips are user-visible switches; 0→x means fcitx5 just started.
    if ((root.lastAnnounced === 1 || root.lastAnnounced === 2)
        && (imState === 1 || imState === 2)) {
      root.toast()
    }
    root.lastAnnounced = imState
  }

  Component.onCompleted: root.refresh()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      // Per-program state moves when focus moves.
      if (String(event.name).indexOf("activewindow") === 0) root.refresh()
    }
  }

  Process {
    id: queryProc
    // --check prevents D-Bus autostart while installers deliberately stop
    // fcitx5; plain fcitx5-remote can spawn an unmanaged competing instance.
    command: ["fcitx5-remote", "--check"]
    onRunningChanged: {
      if (running) {
        stallTimer.restart()
        return
      }
      stallTimer.stop()
      if (root.refreshPending) root.refresh()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const n = parseInt(String(text).trim(), 10)
        if (!isFinite(n) || n < 0) return
        root.imState = n
      }
    }
  }

  // fcitx5-remote never answers while the service is down (dbus timeout);
  // give up so the next poll gets through instead of wedging the widget.
  Timer {
    id: stallTimer
    interval: 4000
    onTriggered: {
      queryProc.running = false
      pollTimer.restart()
    }
  }

  // Safety net for toggles nothing announced (Ctrl+Space in the focused app
  // raises no Hyprland event). Cheap: one short-lived process per tick.
  Timer {
    id: pollTimer
    interval: root.pollMs > 300 ? root.pollMs : 2000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    // Let fcitx5 settle after a toggle before reading back.
    id: clickTimer
    interval: 250
    onTriggered: root.refresh()
  }

  visible: imRunning
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.imActive ? "中" : "A"
    fontSize: Style.font.caption
    horizontalMargin: 6
    // Accent while composing so the state reads at a glance; dimmed A for
    // English mode keeps the widget present but quiet.
    foreground: root.imActive ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground)
    dimmed: !root.imActive
    tooltipText: root.imActive ? "中文输入法 · 左键切换 · 右键设置" : "英文 · 左键切换 · 右键设置"
    onPressed: function(button) {
      if (button === 2) {
        // right-click → settings panel
        if (root.bar) root.bar.run("omarchy-shell shell toggle omarime.settings '{}'")
        return
      }
      if (root.bar) root.bar.run("fcitx5-remote -t")
      clickTimer.restart()
    }
  }
}
