import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// 中/EN input method indicator for the omarchy bar.
//
// Reads fcitx5's active state (fcitx5-remote: 1 inactive / 2 active) and
// renders the same 中/A convention as the fcitx5 tray icon, in desktop
// tokens: 中 in accent while composing, A dimmed while in English mode.
// Click toggles, exactly like Ctrl+Space; the bar itself is the feedback.
//
// The macro-ime-state fcitx5 addon watches activation/deactivation/switch/focus
// events inside fcitx5 and writes $XDG_RUNTIME_DIR/macro-ime/state. FileView
// turns that into an immediate bar update without polling processes. A
// low-frequency check only recovers from addon/service failures.

BarWidget {
  id: root
  moduleName: "macro-ime.indicator"

  // per-widget shell.json override: {"fallbackPollMs": 30000}
  readonly property int fallbackPollMs: root.setting("fallbackPollMs", 30000)
  readonly property string statePath: Quickshell.env("XDG_RUNTIME_DIR") + "/macro-ime/state"

  // fcitx5-remote state: 0 not running, 1 inactive, 2 active
  property int imState: 0
  readonly property bool imActive: imState === 2
  readonly property bool imRunning: imState > 0

  // Only fallback checks use this process. Queue one retry if a check is
  // already in flight; normal state changes arrive through FileView.
  property bool refreshPending: false

  function refresh() {
    if (queryProc.running) {
      refreshPending = true
      return
    }
    refreshPending = false
    queryProc.running = true
  }

  function applyState(text) {
    const n = parseInt(String(text).trim(), 10)
    if (isFinite(n) && n >= 0 && n <= 2) root.imState = n
  }

  Component.onCompleted: root.refresh()

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
    onLoadFailed: root.refresh()
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

  // Recovery only; normal input-mode and focus changes are file events.
  Timer {
    id: pollTimer
    interval: root.fallbackPollMs >= 5000 ? root.fallbackPollMs : 30000
    running: true
    repeat: true
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
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    tooltipText: root.imActive ? "Macro IME · 中文 (左键切换 · 右键设置)" : "Macro IME · 英文 (左键切换 · 右键设置)"
    onPressed: function(button) {
      if (button === 2) {
        // right-click → settings panel
        if (root.bar) root.bar.run("omarchy-shell shell toggle macro-ime.settings '{}'")
        return
      }
      if (root.bar) root.bar.run("fcitx5-remote -t")
    }
  }
}
